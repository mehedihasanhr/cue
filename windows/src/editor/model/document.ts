// One document = one undo state. From the Mac's `EditorDocument.swift`.

import type { Annotation, Point, Rect, RGBA } from "./types";

export type GradientName =
  | "ocean" | "sunset" | "aurora" | "candy" | "peach" | "lime" | "lavender" | "flame" | "mint" | "rose"
  | "sky" | "dusk" | "forest" | "gold" | "berry" | "steel" | "midnight" | "graphite" | "mono" | "snow";

export type BackgroundFill = { type: "solid"; color: RGBA } | { type: "gradient"; name: GradientName };

export const RATIOS = {
  auto: null, square: 1, "4:3": 4 / 3, "3:2": 3 / 2, "16:9": 16 / 9, "16:10": 16 / 10,
  "9:16": 9 / 16, "3:4": 3 / 4, "2:3": 2 / 3, "4:5": 4 / 5,
} as const;
export type Ratio = keyof typeof RATIOS;

export type Background = {
  padding: number;
  /** Padding from the image's size instead of the slider. */
  autoBalance: boolean;
  /** Border inside the card, filled with the image's own edge colour. */
  inset: number;
  cornerRadius: number;
  fill: BackgroundFill;
  /** 0 = none … 1 = strongest. */
  shadow: number;
  /** 0 = leading/top … 1 = trailing/bottom. */
  alignment: Point;
  ratio: Ratio;
  /** Degrees, clockwise from top → bottom. */
  gradientAngle: number;
};

export const DEFAULT_BACKGROUND: Background = {
  padding: 48, autoBalance: false, inset: 0, cornerRadius: 12, fill: { type: "gradient", name: "ocean" },
  shadow: 0.45, alignment: { x: 0.5, y: 0.5 }, ratio: "auto", gradientAngle: 45,
};

export type Doc = {
  /** The image in points. */
  width: number;
  height: number;
  /** Pixels per point. */
  scale: number;
  annotations: Annotation[];
  crop: Rect | null;
  background: Background | null;
  nextCounter: number;
};

export type Layout = { width: number; height: number; card: Rect; image: Rect };

export function contentRect(doc: Doc): Rect {
  return doc.crop ?? { x: 0, y: 0, width: doc.width, height: doc.height };
}

export function effectivePadding(background: Background, content: { width: number; height: number }): number {
  return background.autoBalance ? Math.round(Math.max(content.width, content.height) * 0.08) : background.padding;
}

/** Where the card and the image land in the output. The canvas grows, never crops, to a ratio. */
export function layout(doc: Doc): Layout {
  const content = contentRect(doc);
  const background = doc.background;
  if (!background) {
    const rect = { x: 0, y: 0, width: content.width, height: content.height };
    return { width: content.width, height: content.height, card: rect, image: rect };
  }
  const padding = effectivePadding(background, content);
  const inset = background.inset;
  const card = { width: content.width + inset * 2, height: content.height + inset * 2 };
  let width = card.width + padding * 2;
  let height = card.height + padding * 2;
  const ratio = RATIOS[background.ratio];
  if (ratio) {
    if (width / height < ratio) width = Math.round(height * ratio);
    else height = Math.round(width / ratio);
  }
  const slackX = width - card.width - padding * 2;
  const slackY = height - card.height - padding * 2;
  const cardRect = {
    x: Math.round(padding + slackX * background.alignment.x),
    y: Math.round(padding + slackY * background.alignment.y),
    ...card,
  };
  const image = { x: cardRect.x + inset, y: cardRect.y + inset, width: content.width, height: content.height };
  return { width, height, card: cardRect, image };
}

/** Image point p is drawn at p + offset in output space. */
export function contentOffset(doc: Doc): Point {
  const image = layout(doc).image;
  const content = contentRect(doc);
  return { x: image.x - content.x, y: image.y - content.y };
}

export const GRADIENTS: Record<GradientName, RGBA[]> = {
  ocean: [{ r: 0.27, g: 0.65, b: 1 }, { r: 0.36, g: 0.32, b: 0.9 }],
  sunset: [{ r: 1, g: 0.55, b: 0.35 }, { r: 0.98, g: 0.29, b: 0.53 }],
  aurora: [{ r: 0.2, g: 0.85, b: 0.7 }, { r: 0.3, g: 0.45, b: 0.95 }],
  candy: [{ r: 1, g: 0.6, b: 0.85 }, { r: 0.65, g: 0.5, b: 1 }],
  peach: [{ r: 1, g: 0.8, b: 0.6 }, { r: 1, g: 0.5, b: 0.55 }],
  lime: [{ r: 0.75, g: 0.95, b: 0.45 }, { r: 0.2, g: 0.75, b: 0.55 }],
  lavender: [{ r: 0.85, g: 0.8, b: 1 }, { r: 0.55, g: 0.45, b: 0.95 }],
  flame: [{ r: 1, g: 0.85, b: 0.3 }, { r: 1, g: 0.35, b: 0.2 }, { r: 0.6, g: 0.05, b: 0.3 }],
  mint: [{ r: 0.7, g: 1, b: 0.9 }, { r: 0.25, g: 0.8, b: 0.75 }],
  rose: [{ r: 1, g: 0.75, b: 0.8 }, { r: 0.9, g: 0.3, b: 0.5 }],
  sky: [{ r: 0.75, g: 0.9, b: 1 }, { r: 0.3, g: 0.6, b: 1 }],
  dusk: [{ r: 0.98, g: 0.6, b: 0.4 }, { r: 0.55, g: 0.3, b: 0.65 }, { r: 0.15, g: 0.15, b: 0.4 }],
  forest: [{ r: 0.35, g: 0.7, b: 0.45 }, { r: 0.05, g: 0.3, b: 0.25 }],
  gold: [{ r: 1, g: 0.9, b: 0.55 }, { r: 0.85, g: 0.6, b: 0.15 }],
  berry: [{ r: 0.8, g: 0.3, b: 0.7 }, { r: 0.3, g: 0.1, b: 0.5 }],
  steel: [{ r: 0.75, g: 0.8, b: 0.88 }, { r: 0.35, g: 0.42, b: 0.55 }],
  midnight: [{ r: 0.13, g: 0.15, b: 0.3 }, { r: 0.05, g: 0.05, b: 0.12 }],
  graphite: [{ r: 0.35, g: 0.36, b: 0.4 }, { r: 0.12, g: 0.12, b: 0.14 }],
  mono: [{ r: 0.2, g: 0.2, b: 0.22 }, { r: 0.02, g: 0.02, b: 0.03 }],
  snow: [{ r: 1, g: 1, b: 1 }, { r: 0.85, g: 0.88, b: 0.93 }],
};

export const BACKGROUND_COLORS: RGBA[] = [
  { r: 1, g: 1, b: 1 }, { r: 0.93, g: 0.93, b: 0.95 }, { r: 0.75, g: 0.76, b: 0.8 }, { r: 0.56, g: 0.56, b: 0.58 },
  { r: 0.2, g: 0.2, b: 0.22 }, { r: 0, g: 0, b: 0 }, { r: 0.055, g: 0.31, b: 0.925 }, { r: 0.04, g: 0.52, b: 1 },
  { r: 0.35, g: 0.78, b: 0.98 }, { r: 0.2, g: 0.78, b: 0.7 }, { r: 0.2, g: 0.78, b: 0.35 }, { r: 0.85, g: 0.95, b: 0.55 },
  { r: 1, g: 0.84, b: 0.04 }, { r: 1, g: 0.58, b: 0 }, { r: 1, g: 0.23, b: 0.19 }, { r: 1, g: 0.18, b: 0.33 },
  { r: 0.69, g: 0.32, b: 0.87 }, { r: 0.5, g: 0.35, b: 0.25 },
];
