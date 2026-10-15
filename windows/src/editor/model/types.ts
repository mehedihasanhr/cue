// The editor's model: what can be drawn, in image points (pixels ÷ display scale), origin
// top left, y down — as on the Mac, so a 4-point stroke looks the same at 100% and 150%.

export type Point = { x: number; y: number };
export type Rect = { x: number; y: number; width: number; height: number };
/** Components 0…1. */
export type RGBA = { r: number; g: number; b: number; a?: number };

export type StrokeStyle = { color: RGBA; width: number };
export type FillMode = "none" | "solid" | "translucent";
export type ShapeStyle = { stroke: StrokeStyle; fill: FillMode };
export type ArrowStyle = "single" | "double";
export type TextBackground = "none" | "solid" | "translucent";
/** `weight` is a CSS font weight, 300…900. */
export type TextStyle = { color: RGBA; fontSize: number; background: TextBackground; weight: number };
export type BlurKind = "blur" | "pixelate";

export type AnnotationKind =
  | { type: "rectangle"; rect: Rect; style: ShapeStyle }
  | { type: "ellipse"; rect: Rect; style: ShapeStyle }
  | { type: "line"; start: Point; end: Point; style: StrokeStyle }
  /** `bend` offsets the curve's control point from the midpoint; zero is straight. */
  | { type: "arrow"; start: Point; end: Point; bend: Point; style: StrokeStyle; arrowStyle: ArrowStyle }
  | { type: "pencil"; points: Point[]; style: StrokeStyle }
  | { type: "highlighter"; points: Point[]; style: StrokeStyle }
  /** A marker box behind text: translucent multiply fill. */
  | { type: "highlight"; rect: Rect; color: RGBA }
  | { type: "text"; origin: Point; text: string; style: TextStyle }
  | { type: "counter"; center: Point; number: number; color: RGBA; size: number }
  | { type: "blur"; rect: Rect; kind: BlurKind; intensity: number };

export type Annotation = AnnotationKind & {
  id: string;
  /** Radians, clockwise, about the centre of its bounds. Boxes and text only. */
  rotation: number;
};

export const COLORS = {
  red: { r: 1, g: 0.23, b: 0.19 },
  orange: { r: 1, g: 0.58, b: 0 },
  yellow: { r: 1, g: 0.84, b: 0.04 },
  green: { r: 0.2, g: 0.78, b: 0.35 },
  blue: { r: 0.04, g: 0.52, b: 1 },
  purple: { r: 0.69, g: 0.32, b: 0.87 },
  pink: { r: 1, g: 0.18, b: 0.33 },
  white: { r: 1, g: 1, b: 1 },
  black: { r: 0, g: 0, b: 0 },
  gray: { r: 0.56, g: 0.56, b: 0.58 },
} satisfies Record<string, RGBA>;

export const PALETTE: RGBA[] = Object.values(COLORS);

export function css(color: RGBA, alpha = color.a ?? 1): string {
  return `rgba(${Math.round(color.r * 255)}, ${Math.round(color.g * 255)}, ${Math.round(color.b * 255)}, ${alpha})`;
}

export function isLight(color: RGBA): boolean {
  return 0.299 * color.r + 0.587 * color.g + 0.114 * color.b > 0.6;
}

export const sameColor = (a: RGBA, b: RGBA) =>
  Math.abs(a.r - b.r) < 0.01 && Math.abs(a.g - b.g) < 0.01 && Math.abs(a.b - b.b) < 0.01;
