// What the search field can work out on the spot, as cards to copy — the Mac's
// `Support/QuickAnswers.swift`: a colour in the formats developers paste, a Unix
// timestamp as a date, hex ↔ decimal ↔ binary, px ↔ rem, base64, a UUID, now, a sum.

import { FORMAT_TITLES, format, parseHex, type ColorFormat, type PickedColor } from "./colormath";
import type { IconName } from "../ui/icon";

export type QuickAnswer = { id: string; value: string; label: string; symbol: IconName; color?: PickedColor };

export function answers(raw: string, now = new Date()): QuickAnswer[] {
  const query = raw.trim();
  if (!query) return [];
  // Numbers first: "0b1010" is binary, not the colour #0B1010.
  return number(query) ?? color(query) ?? timestamp(query) ?? length(query) ?? base64(query) ?? uuid(query) ?? today(query, now) ?? math(query) ?? [];
}

const COLOR_FORMATS: ColorFormat[] = ["hex", "rgb", "hsl", "oklch", "displayP3", "swiftUI"];

function color(query: string): QuickAnswer[] | null {
  const body = query.startsWith("#") ? query.slice(1) : query;
  // Without a "#", six plain digits are a number, not a colour.
  if (!(query.startsWith("#") || ((body.length === 6 || body.length === 8) && /\p{L}/u.test(body)))) return null;
  const c = parseHex(query);
  if (!c) return null;
  return COLOR_FORMATS.map((f) => ({ id: `color.${f}`, value: format(c, f), label: FORMAT_TITLES[f], symbol: "paintpalette", color: c }));
}

function timestamp(query: string): QuickAnswer[] | null {
  if (!/^\d+$/.test(query)) return null;
  let seconds: number;
  if (query.length >= 9 && query.length <= 10) seconds = Number(query);
  else if (query.length >= 12 && query.length <= 13) seconds = Number(query) / 1000;
  else return null;
  const date = new Date(seconds * 1000);
  return [
    {
      id: "ts.local",
      value: date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }),
      label: query.length > 10 ? "Date from Unix milliseconds" : "Date from Unix seconds",
      symbol: "calendar",
    },
    { id: "ts.iso", value: date.toISOString().replace(/\.\d{3}Z$/, "Z"), label: "ISO 8601 (UTC)", symbol: "globe" },
    { id: "ts.relative", value: relative(date), label: "From now", symbol: "clock.arrow.circlepath" },
  ];
}

/** "3 days ago", "in 2 hours" — named, as the Mac's relative style is. */
export function relative(date: Date, now = new Date()): string {
  const seconds = (date.getTime() - now.getTime()) / 1000;
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60], ["second", 1],
  ];
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size || unit === "second") return formatter.format(Math.round(seconds / size), unit);
  }
  return "";
}

function today(query: string, date: Date): QuickAnswer[] | null {
  if (!["now", "time", "today", "date"].includes(query.toLowerCase())) return null;
  return [
    { id: "now.unix", value: String(Math.floor(date.getTime() / 1000)), label: "Unix seconds", symbol: "number" },
    { id: "now.iso", value: date.toISOString().replace(/\.\d{3}Z$/, "Z"), label: "ISO 8601 (UTC)", symbol: "globe" },
    { id: "now.date", value: date.toLocaleDateString(undefined, { dateStyle: "full" }), label: "Today", symbol: "calendar" },
    { id: "now.time", value: date.toLocaleTimeString(undefined, { timeStyle: "medium" }), label: "Time", symbol: "clock" },
  ];
}

function number(query: string): QuickAnswer[] | null {
  const lower = query.toLowerCase();
  let value: bigint;
  if (lower.startsWith("0x") && /^[0-9a-f]+$/.test(lower.slice(2))) value = BigInt("0x" + lower.slice(2));
  else if (lower.startsWith("0b") && /^[01]+$/.test(lower.slice(2))) value = BigInt("0b" + lower.slice(2));
  else if (/^\d{1,8}$/.test(lower)) value = BigInt(lower);
  else return null;
  return [
    { id: "n.dec", value: value.toString(), label: "Decimal", symbol: "number" as IconName },
    { id: "n.hex", value: "0x" + value.toString(16).toUpperCase(), label: "Hex", symbol: "number" as IconName },
    { id: "n.bin", value: "0b" + value.toString(2), label: "Binary", symbol: "number" as IconName },
    { id: "n.oct", value: "0o" + value.toString(8), label: "Octal", symbol: "number" as IconName },
  ].filter((a) => a.value.toLowerCase() !== lower);
}

function length(query: string): QuickAnswer[] | null {
  const match = query.toLowerCase().match(/^(\d+(?:\.\d+)?)\s*(px|rem|em|pt)$/);
  if (!match) return null;
  const amount = Number(match[1]);
  const px = match[2] === "px" ? amount : match[2] === "pt" ? (amount * 4) / 3 : amount * 16;
  const typed = query.toLowerCase().replace(/ /g, "");
  return [
    { id: "len.px", value: `${plain(px)}px`, label: "Pixels", symbol: "ruler" as IconName },
    { id: "len.rem", value: `${plain(px / 16)}rem`, label: "rem at 16 px", symbol: "ruler" as IconName },
    { id: "len.em", value: `${plain(px / 16)}em`, label: "em at 16 px", symbol: "ruler" as IconName },
    { id: "len.pt", value: `${plain((px * 3) / 4)}pt`, label: "Points (CSS)", symbol: "ruler" as IconName },
  ].filter((a) => a.value !== typed);
}

function base64(query: string): QuickAnswer[] | null {
  const lower = query.toLowerCase();
  for (const prefix of ["base64 ", "b64 ", "encode "]) {
    if (lower.startsWith(prefix)) {
      const text = query.slice(prefix.length);
      if (!text) return null;
      const bytes = new TextEncoder().encode(text);
      return [{ id: "b64.enc", value: btoa(String.fromCharCode(...bytes)), label: "Base64", symbol: "lock.doc" }];
    }
  }
  const candidate = lower.startsWith("decode ") ? query.slice(7) : query;
  if (candidate.length < 8 || candidate.length % 4 !== 0 || !/^[\p{L}\p{N}+/=]+$/u.test(candidate) || !/\p{L}/u.test(candidate)) return null;
  try {
    const binary = atob(candidate);
    const text = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(binary, (c) => c.charCodeAt(0)));
    // eslint-disable-next-line no-control-regex
    if (!text || /[\x00-\x09\x0b-\x1f]/.test(text)) return null;
    return [{ id: "b64.dec", value: text, label: "Decoded from Base64", symbol: "lock.open.doc" }];
  } catch {
    return null;
  }
}

function uuid(query: string): QuickAnswer[] | null {
  if (!["uuid", "guid"].includes(query.toLowerCase())) return null;
  const id = crypto.randomUUID().toUpperCase();
  return [
    { id: "uuid.upper", value: id, label: "New UUID", symbol: "number.square" },
    { id: "uuid.lower", value: id.toLowerCase(), label: "New UUID, lowercase", symbol: "number.square" },
  ];
}

function math(query: string): QuickAnswer[] | null {
  if (!/^[0-9.+\-*/()%^ ×÷]+$/.test(query) || !/\d/.test(query) || !/[+\-*/%^×÷]/.test(query)) return null;
  const result = evaluate(query);
  if (result === null || !Number.isFinite(result)) return null;
  return [{ id: "math", value: plain(result), label: `= ${query}`, symbol: "function" }];
}

/** A small recursive-descent evaluator: + − × ÷ % ^ and brackets. */
export function evaluate(text: string): number | null {
  const chars = [...text.replace(/×/g, "*").replace(/÷/g, "/").replace(/\s/g, "")];
  let i = 0;
  const sum = (): number | null => {
    let left = product();
    if (left === null) return null;
    while (i < chars.length && (chars[i] === "+" || chars[i] === "-")) {
      const op = chars[i++];
      const right = product();
      if (right === null) return null;
      left = op === "+" ? left + right : left - right;
    }
    return left;
  };
  const product = (): number | null => {
    let left = power();
    if (left === null) return null;
    while (i < chars.length && "*/%".includes(chars[i])) {
      const op = chars[i++];
      const right = power();
      if (right === null) return null;
      left = op === "*" ? left * right : op === "/" ? left / right : left % right;
    }
    return left;
  };
  const power = (): number | null => {
    const base = unary();
    if (base === null) return null;
    if (chars[i] === "^") {
      i++;
      const exponent = power();
      return exponent === null ? null : Math.pow(base, exponent);
    }
    return base;
  };
  const unary = (): number | null => {
    if (chars[i] === "-") {
      i++;
      const v = unary();
      return v === null ? null : -v;
    }
    if (chars[i] === "+") {
      i++;
      return unary();
    }
    return atom();
  };
  const atom = (): number | null => {
    if (i >= chars.length) return null;
    if (chars[i] === "(") {
      i++;
      const inner = sum();
      if (inner === null || chars[i] !== ")") return null;
      i++;
      return inner;
    }
    const start = i;
    while (i < chars.length && /[\d.]/.test(chars[i])) i++;
    if (i === start) return null;
    const value = Number(chars.slice(start, i).join(""));
    return Number.isNaN(value) ? null : value;
  };
  const value = sum();
  return value !== null && i === chars.length ? value : null;
}

/** A number without trailing zeros, up to six decimals: "16", "2.5", "0.333333". */
export function plain(value: number): string {
  return Number(value.toFixed(6)).toString();
}
