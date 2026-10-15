// A colour and the strings it can be copied as — the Mac's `Colors/ColorMath.swift`,
// conversion for conversion (CSS Color 4), so both apps copy the same text.

/** Exact sRGB components (not clamped) and alpha, as the Mac stores them. */
export type PickedColor = { red: number; green: number; blue: number; alpha?: number };

export const FORMATS = [
  "hex", "hexAlpha", "rgb", "rgba", "hsl", "hsb", "oklch", "oklab", "lch", "lab", "displayP3", "cmyk", "swiftUI", "nsColor", "uiColor",
] as const;
export type ColorFormat = (typeof FORMATS)[number];

export const FORMAT_TITLES: Record<ColorFormat, string> = {
  hex: "HEX", hexAlpha: "HEX with alpha", rgb: "RGB", rgba: "RGBA", hsl: "HSL", hsb: "HSB", oklch: "OKLCH", oklab: "OKLab",
  lch: "LCH", lab: "Lab", displayP3: "Display P3", cmyk: "CMYK", swiftUI: "SwiftUI", nsColor: "NSColor", uiColor: "UIColor",
};

const clamp01 = (v: number) => Math.min(Math.max(v, 0), 1);

export function clamped(c: PickedColor): [number, number, number] {
  return [clamp01(c.red), clamp01(c.green), clamp01(c.blue)];
}

export function inSRGB(c: PickedColor): boolean {
  return [c.red, c.green, c.blue].every((v) => v >= -0.0005 && v <= 1.0005);
}

function toLinear(c: number): number {
  const sign = c < 0 ? -1 : 1;
  const a = Math.abs(c);
  return sign * (a <= 0.04045 ? a / 12.92 : Math.pow((a + 0.055) / 1.055, 2.4));
}

function fromLinear(c: number): number {
  const sign = c < 0 ? -1 : 1;
  const a = Math.abs(c);
  return sign * (a <= 0.0031308 ? a * 12.92 : 1.055 * Math.pow(a, 1 / 2.4) - 0.055);
}

function hueOf(a: number, b: number): number {
  if (Math.abs(a) <= 1e-9 && Math.abs(b) <= 1e-9) return 0;
  const degrees = (Math.atan2(b, a) * 180) / Math.PI;
  return degrees < 0 ? degrees + 360 : degrees;
}

function rgbHue(r: number, g: number, b: number, max: number, delta: number): number {
  let h: number;
  if (max === r) h = (g - b) / delta + (g < b ? 6 : 0);
  else if (max === g) h = (b - r) / delta + 2;
  else h = (r - g) / delta + 4;
  h *= 60;
  return h < 0 ? h + 360 : h;
}

function linear(c: PickedColor): [number, number, number] {
  return [toLinear(c.red), toLinear(c.green), toLinear(c.blue)];
}

function xyz(c: PickedColor): [number, number, number] {
  const [r, g, b] = linear(c);
  return [
    0.41239079926595934 * r + 0.357584339383878 * g + 0.1804807884018343 * b,
    0.21263900587151027 * r + 0.715168678767756 * g + 0.07219231536073371 * b,
    0.01933081871559182 * r + 0.11919477979462598 * g + 0.9505321522496607 * b,
  ];
}

export function oklab(c: PickedColor): [number, number, number] {
  const [r, g, b] = linear(c);
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function oklch(c: PickedColor): [number, number, number] {
  const [l, a, b] = oklab(c);
  return [l, Math.hypot(a, b), hueOf(a, b)];
}

function lab(c: PickedColor): [number, number, number] {
  const [x, y, z] = xyz(c);
  const xd = 1.0479298208405488 * x + 0.022946793341019088 * y - 0.05019222954313557 * z;
  const yd = 0.029627815688159344 * x + 0.990434484573249 * y - 0.01707382502938514 * z;
  const zd = -0.009243058152591178 * x + 0.015055144896577895 * y + 0.7518742899580008 * z;
  const white = [0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585];
  const f = (t: number) => {
    const epsilon = 216 / 24389;
    const kappa = 24389 / 27;
    return t > epsilon ? Math.cbrt(t) : (kappa * t + 16) / 116;
  };
  const fx = f(xd / white[0]);
  const fy = f(yd / white[1]);
  const fz = f(zd / white[2]);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

function lch(c: PickedColor): [number, number, number] {
  const [l, a, b] = lab(c);
  return [l, Math.hypot(a, b), hueOf(a, b)];
}

function displayP3(c: PickedColor): [number, number, number] {
  const [x, y, z] = xyz(c);
  const r = 2.493496911941425 * x - 0.9313836179191239 * y - 0.40271078445071684 * z;
  const g = -0.8294889695615747 * x + 1.7626640603183463 * y + 0.023624685841943577 * z;
  const b = 0.03584583024378447 * x - 0.07617238926804182 * y + 0.9568845240076872 * z;
  return [fromLinear(r), fromLinear(g), fromLinear(b)];
}

function hsl(c: PickedColor): [number, number, number] {
  const [r, g, b] = clamped(c);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d <= 1e-9) return [0, 0, l];
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  return [rgbHue(r, g, b, max, d), s, l];
}

function hsb(c: PickedColor): [number, number, number] {
  const [r, g, b] = clamped(c);
  const max = Math.max(r, g, b);
  const d = max - Math.min(r, g, b);
  if (max <= 1e-9 || d <= 1e-9) return [0, 0, max];
  return [rgbHue(r, g, b, max, d), d / max, max];
}

function cmyk(c: PickedColor): [number, number, number, number] {
  const [r, g, b] = clamped(c);
  const k = 1 - Math.max(r, g, b);
  if (k >= 1 - 1e-9) return [0, 0, 0, 1];
  return [(1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k];
}

/** Fixed decimals with trailing zeros trimmed ("62.8", "0.2577", "100"). */
export function number(value: number, decimals: number): string {
  let s = value.toFixed(decimals);
  if (s.includes(".")) s = s.replace(/0+$/, "").replace(/\.$/, "");
  return s === "-0" ? "0" : s;
}

const hex2 = (v: number) => Math.round(v * 255).toString(16).toUpperCase().padStart(2, "0");

export function format(c: PickedColor, f: ColorFormat): string {
  const [r, g, b] = clamped(c);
  const r8 = Math.round(r * 255);
  const g8 = Math.round(g * 255);
  const b8 = Math.round(b * 255);
  const alpha = c.alpha ?? 1;
  switch (f) {
    case "hex": return `#${hex2(r)}${hex2(g)}${hex2(b)}`;
    case "hexAlpha": return `#${hex2(r)}${hex2(g)}${hex2(b)}${hex2(alpha)}`;
    case "rgb": return `rgb(${r8}, ${g8}, ${b8})`;
    case "rgba": return `rgba(${r8}, ${g8}, ${b8}, ${number(alpha, 2)})`;
    case "hsl": { const [h, s, l] = hsl(c); return `hsl(${number(h, 1)}, ${number(s * 100, 1)}%, ${number(l * 100, 1)}%)`; }
    case "hsb": { const [h, s, v] = hsb(c); return `hsb(${number(h, 1)}, ${number(s * 100, 1)}%, ${number(v * 100, 1)}%)`; }
    case "oklch": { const [l, ch, h] = oklch(c); return `oklch(${number(l * 100, 2)}% ${number(ch, 4)} ${number(h, 2)})`; }
    case "oklab": { const [l, a, bb] = oklab(c); return `oklab(${number(l * 100, 2)}% ${number(a, 4)} ${number(bb, 4)})`; }
    case "lch": { const [l, ch, h] = lch(c); return `lch(${number(l, 2)}% ${number(ch, 2)} ${number(h, 2)})`; }
    case "lab": { const [l, a, bb] = lab(c); return `lab(${number(l, 2)}% ${number(a, 2)} ${number(bb, 2)})`; }
    case "displayP3": { const [pr, pg, pb] = displayP3(c); return `color(display-p3 ${number(pr, 4)} ${number(pg, 4)} ${number(pb, 4)})`; }
    case "cmyk": { const [cc, m, y, k] = cmyk(c); return `cmyk(${number(cc * 100, 0)}%, ${number(m * 100, 0)}%, ${number(y * 100, 0)}%, ${number(k * 100, 0)}%)`; }
    case "swiftUI": return `Color(red: ${number(r, 3)}, green: ${number(g, 3)}, blue: ${number(b, 3)})`;
    case "nsColor": return `NSColor(srgbRed: ${number(r, 3)}, green: ${number(g, 3)}, blue: ${number(b, 3)}, alpha: ${number(alpha, 2)})`;
    case "uiColor": return `UIColor(red: ${number(r, 3)}, green: ${number(g, 3)}, blue: ${number(b, 3)}, alpha: ${number(alpha, 2)})`;
  }
}

/** `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, with or without the `#`. */
export function parseHex(text: string): PickedColor | null {
  let body = text.trim();
  if (body.startsWith("#")) body = body.slice(1);
  if (!/^[0-9a-fA-F]+$/.test(body)) return null;
  if (body.length === 3 || body.length === 4) body = [...body].map((c) => c + c).join("");
  if (body.length !== 6 && body.length !== 8) return null;
  const at = (i: number) => parseInt(body.slice(i, i + 2), 16) / 255;
  return { red: at(0), green: at(2), blue: at(4), alpha: body.length === 8 ? at(6) : 1 };
}

/** The colour as CSS can draw it. */
export function cssColor(c: PickedColor): string {
  const [r, g, b] = clamped(c);
  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${c.alpha ?? 1})`;
}

/** Whether black text reads better than white on it. */
export function isLight(c: PickedColor): boolean {
  const [r, g, b] = clamped(c);
  return 0.299 * r + 0.587 * g + 0.114 * b > 0.62;
}
