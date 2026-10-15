// The geometry of choosing an area, in physical pixels of one display. Ported from the
// Mac's `SelectionView` and `WindowDetector` so both feel the same in the hand.

export type Point = { x: number; y: number };
export type Rect = { x: number; y: number; width: number; height: number };

/** Edges pull the pointer in from this far, in points (scaled by the display). */
export const SNAP_TOLERANCE = 8;
/** Less movement than this between press and release is a click, not a drag. */
export const CLICK_SLOP = 3;
/** Anything smaller is not a selection. */
export const MINIMUM_SIZE = 2;

export function rectFrom(a: Point, b: Point): Rect {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    width: Math.abs(b.x - a.x),
    height: Math.abs(b.y - a.y),
  };
}

export function contains(rect: Rect, p: Point): boolean {
  return p.x >= rect.x && p.x < rect.x + rect.width && p.y >= rect.y && p.y < rect.y + rect.height;
}

/** The frontmost window under `p`; windows are listed front to back. */
export function windowAt(p: Point, windows: Rect[]): number {
  return windows.findIndex((w) => contains(w, p));
}

/** Snaps each axis of `p` to the nearest window edge within `tolerance`. */
export function snap(p: Point, windows: Rect[], tolerance: number): Point {
  const snapped = { ...p };
  let bestX = tolerance;
  let bestY = tolerance;
  for (const w of windows) {
    for (const x of [w.x, w.x + w.width]) {
      if (Math.abs(x - p.x) < bestX) {
        bestX = Math.abs(x - p.x);
        snapped.x = x;
      }
    }
    for (const y of [w.y, w.y + w.height]) {
      if (Math.abs(y - p.y) < bestY) {
        bestY = Math.abs(y - p.y);
        snapped.y = y;
      }
    }
  }
  return snapped;
}

/** `p` moved so the rectangle from `anchor` is a square, keeping its direction. */
export function square(anchor: Point, p: Point): Point {
  const side = Math.max(Math.abs(p.x - anchor.x), Math.abs(p.y - anchor.y));
  return {
    x: anchor.x + side * (p.x >= anchor.x ? 1 : -1),
    y: anchor.y + side * (p.y >= anchor.y ? 1 : -1),
  };
}

/** `rect` cut to the display and rounded to whole pixels; null if nothing is left. */
export function clamp(rect: Rect, width: number, height: number): Rect | null {
  const x = Math.max(0, Math.round(rect.x));
  const y = Math.max(0, Math.round(rect.y));
  const right = Math.min(width, Math.round(rect.x + rect.width));
  const bottom = Math.min(height, Math.round(rect.y + rect.height));
  if (right - x < MINIMUM_SIZE || bottom - y < MINIMUM_SIZE) return null;
  return { x, y, width: right - x, height: bottom - y };
}

export function isClick(a: Point, b: Point, scale: number): boolean {
  return Math.hypot(b.x - a.x, b.y - a.y) < CLICK_SLOP * scale;
}
