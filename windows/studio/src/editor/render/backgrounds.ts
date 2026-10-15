// The backgrounds behind the picture — the Mac's `GradientPreset` (BackgroundKit) and the
// renderer's gradient geometry: a sweep 1.5× the output's longer side through its middle,
// at `angle` turns, measured anticlockwise from the right with y up.

import { DEFAULT_GRADIENT, type Background, type RGBA } from "../model/timeline";

type Stops = [number, number, number][];

/** `klik:<name>` wallpapers: evenly spread stops at a quarter turn (bottom to top). */
export const PRESETS: Record<string, Stops> = {
  ocean: [[0.27, 0.65, 1], [0.36, 0.32, 0.9]],
  sunset: [[1, 0.55, 0.35], [0.98, 0.29, 0.53]],
  aurora: [[0.2, 0.85, 0.7], [0.3, 0.45, 0.95]],
  candy: [[1, 0.6, 0.85], [0.65, 0.5, 1]],
  peach: [[1, 0.8, 0.6], [1, 0.5, 0.55]],
  lime: [[0.75, 0.95, 0.45], [0.2, 0.75, 0.55]],
  lavender: [[0.85, 0.8, 1], [0.55, 0.45, 0.95]],
  flame: [[1, 0.85, 0.3], [1, 0.35, 0.2], [0.6, 0.05, 0.3]],
  mint: [[0.7, 1, 0.9], [0.25, 0.8, 0.75]],
  rose: [[1, 0.75, 0.8], [0.9, 0.3, 0.5]],
  sky: [[0.75, 0.9, 1], [0.3, 0.6, 1]],
  dusk: [[0.98, 0.6, 0.4], [0.55, 0.3, 0.65], [0.15, 0.15, 0.4]],
  forest: [[0.35, 0.7, 0.45], [0.05, 0.3, 0.25]],
  gold: [[1, 0.9, 0.55], [0.85, 0.6, 0.15]],
  berry: [[0.8, 0.3, 0.7], [0.3, 0.1, 0.5]],
  steel: [[0.75, 0.8, 0.88], [0.35, 0.42, 0.55]],
  midnight: [[0.13, 0.15, 0.3], [0.05, 0.05, 0.12]],
  graphite: [[0.35, 0.36, 0.4], [0.12, 0.12, 0.14]],
  mono: [[0.2, 0.2, 0.22], [0.02, 0.02, 0.03]],
  snow: [[1, 1, 1], [0.85, 0.88, 0.93]],
};

export const css = (c: RGBA | [number, number, number], alpha = 1) => {
  const [r, g, b, a] = Array.isArray(c) ? [...c, 1] : [c.r, c.g, c.b, c.a];
  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${a * alpha})`;
};

/** Colour stops for a background a gradient can draw; null for the rest. */
export function gradientOf(b: Background): { stops: string[]; angle: number } | null {
  switch (b.kind) {
    case "gradient":
      return { stops: [css(b.from), css(b.to)], angle: b.angle };
    case "wallpaper": {
      const name = b.id.startsWith("klik:") ? b.id.slice(5) : "";
      const preset = PRESETS[name];
      if (preset) return { stops: preset.map((c) => css(c)), angle: 0.25 };
      // A Mac system wallpaper isn't on this PC: the default stands in.
      return gradientOf(DEFAULT_GRADIENT);
    }
    case "other":
      return gradientOf(DEFAULT_GRADIENT);
    default:
      return null;
  }
}

/** The CSS for a swatch of a background. */
export function swatch(b: Background): string {
  if (b.kind === "color") return css(b.color);
  if (b.kind === "transparent") return "repeating-conic-gradient(#ccc 0 25%, #fff 0 50%) 0 0 / 12px 12px";
  const g = gradientOf(b);
  // CSS angles run clockwise from the top; ours anticlockwise from the right.
  return g ? `linear-gradient(${90 - g.angle * 360}deg, ${g.stops.join(", ")})` : "#333";
}

export function paintBackground(ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D, b: Background, w: number, h: number, image?: CanvasImageSource | null, blur = 0) {
  if (b.kind === "transparent") {
    ctx.clearRect(0, 0, w, h);
    return;
  }
  if (b.kind === "color") {
    ctx.fillStyle = css(b.color);
    ctx.fillRect(0, 0, w, h);
    return;
  }
  if (b.kind === "image" && image) {
    // Fills the output, cropped to its middle.
    const iw = (image as HTMLImageElement).naturalWidth || (image as ImageBitmap).width;
    const ih = (image as HTMLImageElement).naturalHeight || (image as ImageBitmap).height;
    const s = Math.max(w / iw, h / ih);
    ctx.save();
    if (blur > 0) ctx.filter = `blur(${blur}px)`;
    const pad = blur * 2;
    ctx.drawImage(image, (w - iw * s) / 2 - pad, (h - ih * s) / 2 - pad, iw * s + pad * 2, ih * s + pad * 2);
    ctx.restore();
    return;
  }
  const g = gradientOf(b) ?? gradientOf(DEFAULT_GRADIENT)!;
  const radians = g.angle * 2 * Math.PI;
  const length = Math.max(w, h) * 1.5;
  const cx = w / 2;
  const cy = h / 2;
  const dx = (Math.cos(radians) * length) / 2;
  const dy = (Math.sin(radians) * length) / 2;
  // y up on the Mac, down here.
  const grad = ctx.createLinearGradient(cx - dx, cy + dy, cx + dx, cy - dy);
  g.stops.forEach((s, i) => grad.addColorStop(g.stops.length === 1 ? 0 : i / (g.stops.length - 1), s));
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, w, h);
}
