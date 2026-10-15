// Bounds, moving, resizing and hit-testing annotations. From the Mac's `Annotation.swift`.

import { distanceToSegment } from "./shapeRecognizer";
import type { Annotation, Point, Rect, TextStyle } from "./types";

export const TEXT_PADDING = { width: 8, height: 4 };

export function rectFrom(a: Point, b: Point): Rect {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) };
}

export function boundsOf(points: Point[]): Rect {
  if (points.length === 0) return { x: 0, y: 0, width: 0, height: 0 };
  let minX = points[0].x, maxX = minX, minY = points[0].y, maxY = minY;
  for (const p of points) {
    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

export function fontFor(style: TextStyle): string {
  return `${style.weight} ${style.fontSize}px "Segoe UI Variable Text", "Segoe UI", sans-serif`;
}

let measurer: CanvasRenderingContext2D | null = null;

/** The text box's size, padding included; "Text" stands in while it is empty. */
export function textSize(text: string, style: TextStyle): { width: number; height: number } {
  measurer ??= document.createElement("canvas").getContext("2d");
  const lines = (text || "Text").split("\n");
  let width = 0;
  if (measurer) {
    measurer.font = fontFor(style);
    for (const line of lines) width = Math.max(width, measurer.measureText(line || " ").width);
  } else {
    width = Math.max(...lines.map((l) => l.length)) * style.fontSize * 0.55;
  }
  const lineHeight = Math.ceil(style.fontSize * 1.25);
  return {
    width: Math.ceil(width) + TEXT_PADDING.width * 2,
    height: lineHeight * lines.length + TEXT_PADDING.height * 2,
  };
}

// MARK: - Arrows: a quadratic curve whose control point is `midpoint + bend`.

export const arrowGeometry = {
  control(start: Point, end: Point, bend: Point): Point {
    return { x: (start.x + end.x) / 2 + bend.x, y: (start.y + end.y) / 2 + bend.y };
  },
  /** The middle handle, on the curve at t = 0.5. */
  handle(start: Point, end: Point, bend: Point): Point {
    return { x: (start.x + end.x) / 2 + bend.x / 2, y: (start.y + end.y) / 2 + bend.y / 2 };
  },
  bendFor(handle: Point, start: Point, end: Point): Point {
    return { x: (handle.x - (start.x + end.x) / 2) * 2, y: (handle.y - (start.y + end.y) / 2) * 2 };
  },
  pointAt(t: number, start: Point, end: Point, bend: Point): Point {
    const c = arrowGeometry.control(start, end, bend);
    const u = 1 - t;
    return { x: u * u * start.x + 2 * u * t * c.x + t * t * end.x, y: u * u * start.y + 2 * u * t * c.y + t * t * end.y };
  },
  tangent(t: number, start: Point, end: Point, bend: Point): Point {
    const c = arrowGeometry.control(start, end, bend);
    let d = { x: 2 * (1 - t) * (c.x - start.x) + 2 * t * (end.x - c.x), y: 2 * (1 - t) * (c.y - start.y) + 2 * t * (end.y - c.y) };
    let length = Math.hypot(d.x, d.y);
    if (length < 0.001) {
      d = { x: end.x - start.x, y: end.y - start.y };
      length = Math.max(Math.hypot(d.x, d.y), 0.001);
    }
    return { x: d.x / length, y: d.y / length };
  },
  points(start: Point, end: Point, bend: Point, samples = 24): Point[] {
    if (bend.x === 0 && bend.y === 0) return [start, end];
    return Array.from({ length: samples + 1 }, (_, i) => arrowGeometry.pointAt(i / samples, start, end, bend));
  },
};

/** Axis-aligned bounds, stroke width not included. */
export function bounds(a: Annotation): Rect {
  switch (a.type) {
    case "rectangle": case "ellipse": case "blur": case "highlight": return a.rect;
    case "line": return rectFrom(a.start, a.end);
    case "arrow": return boundsOf(arrowGeometry.points(a.start, a.end, a.bend));
    case "pencil": case "highlighter": return boundsOf(a.points);
    case "text": return { ...a.origin, ...textSize(a.text, a.style) };
    case "counter": return { x: a.center.x - a.size / 2, y: a.center.y - a.size / 2, width: a.size, height: a.size };
  }
}

export const canRotate = (a: Annotation) => ["rectangle", "ellipse", "highlight", "text"].includes(a.type);
export const isResizable = (a: Annotation) => ["rectangle", "ellipse", "blur", "highlight"].includes(a.type);
export const hasEndpoints = (a: Annotation) => a.type === "line" || a.type === "arrow";

export function center(a: Annotation): Point {
  const b = bounds(a);
  return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
}

export function rotate(p: Point, angle: number, around: Point): Point {
  const dx = p.x - around.x, dy = p.y - around.y;
  const c = Math.cos(angle), s = Math.sin(angle);
  return { x: around.x + dx * c - dy * s, y: around.y + dx * s + dy * c };
}

/** `p` in the annotation's own unrotated frame. */
export const localPoint = (a: Annotation, p: Point) => (a.rotation ? rotate(p, -a.rotation, center(a)) : p);
/** A point of the unrotated frame, where it shows on screen. */
export const worldPoint = (a: Annotation, p: Point) => (a.rotation ? rotate(p, a.rotation, center(a)) : p);

const add = (p: Point, d: Point) => ({ x: p.x + d.x, y: p.y + d.y });
const offset = (r: Rect, d: Point) => ({ ...r, x: r.x + d.x, y: r.y + d.y });

export function moved(a: Annotation, d: Point): Annotation {
  switch (a.type) {
    case "rectangle": case "ellipse": case "blur": case "highlight": return { ...a, rect: offset(a.rect, d) };
    case "line": return { ...a, start: add(a.start, d), end: add(a.end, d) };
    case "arrow": return { ...a, start: add(a.start, d), end: add(a.end, d) };
    case "pencil": case "highlighter": return { ...a, points: a.points.map((p) => add(p, d)) };
    case "text": return { ...a, origin: add(a.origin, d) };
    case "counter": return { ...a, center: add(a.center, d) };
  }
}

export function withRect(a: Annotation, rect: Rect): Annotation {
  return "rect" in a ? ({ ...a, rect } as Annotation) : a;
}

export function withEndpoints(a: Annotation, start: Point, end: Point): Annotation {
  return a.type === "line" || a.type === "arrow" ? { ...a, start, end } : a;
}

function near(points: Point[], p: Point, tolerance: number): boolean {
  if (points.length === 1) return Math.hypot(points[0].x - p.x, points[0].y - p.y) <= tolerance;
  for (let i = 1; i < points.length; i++) {
    if (distanceToSegment(p, points[i - 1], points[i]) <= tolerance) return true;
  }
  return false;
}

/** Whether `p` (image points) lands on `a`; `slop` is the reach in points. */
export function hits(a: Annotation, p: Point, slop: number): boolean {
  const q = localPoint(a, p);
  const inside = (r: Rect, pad = 0) =>
    q.x >= r.x - pad && q.x <= r.x + r.width + pad && q.y >= r.y - pad && q.y <= r.y + r.height + pad;
  switch (a.type) {
    case "rectangle": {
      if (a.style.fill !== "none") return inside(a.rect, slop);
      const r = a.rect;
      const pad = slop + a.style.stroke.width / 2;
      return inside(r, pad) && !(q.x > r.x + pad && q.x < r.x + r.width - pad && q.y > r.y + pad && q.y < r.y + r.height - pad);
    }
    case "ellipse": {
      const rx = a.rect.width / 2, ry = a.rect.height / 2;
      if (rx <= 0 || ry <= 0) return false;
      const nx = (q.x - a.rect.x - rx) / rx, ny = (q.y - a.rect.y - ry) / ry;
      const r = Math.hypot(nx, ny);
      if (a.style.fill !== "none") return r <= 1 + slop / Math.min(rx, ry);
      return Math.abs(r - 1) * Math.min(rx, ry) <= slop + a.style.stroke.width / 2;
    }
    case "blur": case "highlight": case "text": case "counter": return inside(bounds(a), slop / 2);
    case "line": return near([a.start, a.end], q, slop + a.style.width / 2);
    case "arrow": return near(arrowGeometry.points(a.start, a.end, a.bend), q, slop + a.style.width / 2);
    case "pencil": case "highlighter": return near(a.points, q, slop + a.style.width / 2);
  }
}

/** `p` moved to the nearest 45° from `anchor`, for Shift-drawn lines. */
export function constrain45(anchor: Point, p: Point): Point {
  const dx = p.x - anchor.x, dy = p.y - anchor.y;
  const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
  const length = Math.hypot(dx, dy);
  return { x: anchor.x + Math.cos(angle) * length, y: anchor.y + Math.sin(angle) * length };
}

/** `p` moved so the box from `anchor` is square. */
export function constrainSquare(anchor: Point, p: Point): Point {
  const side = Math.max(Math.abs(p.x - anchor.x), Math.abs(p.y - anchor.y));
  return { x: anchor.x + side * Math.sign(p.x - anchor.x || 1), y: anchor.y + side * Math.sign(p.y - anchor.y || 1) };
}
