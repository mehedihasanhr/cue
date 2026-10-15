// The editor's tool settings — colour, widths, font. What a new editor starts with is
// Settings › Editor (`editor` in the settings file, the Mac's `editor.defaults`); with
// "Remember last used" on, it starts with what the last editor was left with instead,
// kept in this PC's web storage.

import { COLORS, type ArrowStyle, type BlurKind, type FillMode, type RGBA, type TextBackground } from "./model/types";

export type Tool =
  | "select" | "crop" | "pencil" | "highlighter" | "highlight" | "shape" | "arrow" | "text" | "blur" | "counter";
export type ShapeKind = "rectangle" | "ellipse" | "line";

export type Prefs = {
  color: RGBA;
  highlightColor: RGBA;
  strokeWidth: number;
  fill: FillMode;
  shapeKind: ShapeKind;
  arrowStyle: ArrowStyle;
  fontSize: number;
  fontWeight: number;
  textBackground: TextBackground;
  highlighterWidth: number;
  blurKind: BlurKind;
  blurIntensity: number;
  counterSize: number;
  smartShapes: boolean;
};

export const DEFAULT_PREFS: Prefs = {
  color: COLORS.red,
  highlightColor: COLORS.yellow,
  strokeWidth: 4,
  fill: "none",
  shapeKind: "rectangle",
  arrowStyle: "single",
  fontSize: 15,
  fontWeight: 600,
  textBackground: "none",
  highlighterWidth: 18,
  blurKind: "blur",
  blurIntensity: 12,
  counterSize: 30,
  smartShapes: true,
};

export const RANGES = {
  strokeWidth: [1, 20],
  fontSize: [8, 96],
  highlighterWidth: [6, 40],
  blurIntensity: [2, 40],
  counterSize: [16, 60],
} as const;

/** Settings › Editor: the defaults, and whether the last editor's options win over them. */
export type EditorDefaults = Prefs & { rememberLastUsed: boolean };

/** Reads the `editor` blob in the settings file, filling in whatever it lacks. */
export function editorDefaults(value: unknown): EditorDefaults {
  const saved = value && typeof value === "object" ? (value as Partial<EditorDefaults>) : {};
  return { ...DEFAULT_PREFS, rememberLastUsed: false, ...saved };
}

const KEY = "klik.editor.prefs";

/** What a new editor starts with, given the settings' `editor` blob. */
export function loadPrefs(settings: unknown): Prefs {
  const { rememberLastUsed, ...defaults } = editorDefaults(settings);
  if (!rememberLastUsed) return defaults;
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") };
  } catch {
    return defaults;
  }
}

export function savePrefs(prefs: Prefs) {
  try {
    localStorage.setItem(KEY, JSON.stringify(prefs));
  } catch {
    // Storage can be unavailable; the defaults still work.
  }
}

export const TOOL_KEYS: Record<string, Tool> = {
  v: "select", c: "crop", p: "pencil", h: "highlighter", m: "highlight", s: "shape", a: "arrow", t: "text", b: "blur", n: "counter",
};
