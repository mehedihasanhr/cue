// Turns a freehand pencil stroke into the shape it was meant to be: a straight line, an
// ellipse, a rectangle or an arrow. Anything it isn't sure about stays a scribble.
// A line-for-line port of the Mac's `ShapeRecognizer.swift`, with its tests.

export type P = { x: number; y: number };
type Box = { x: number; y: number; width: number; height: number };

export type Shape =
  | { kind: "line"; start: P; end: P }
  | { kind: "ellipse"; rect: Box }
  | { kind: "rectangle"; rect: Box }
  | { kind: "arrow"; start: P; end: P };

const gap = (a: P, b: P) => Math.hypot(a.x - b.x, a.y - b.y);

export function recognize(raw: P[]): Shape | null {
  const points = dedupe(raw);
  if (points.length < 3) return null;
  const length = pathLength(points);
  const bounds = boundingBox(points);
  const diagonal = Math.hypot(bounds.width, bounds.height);
  // Too small to be anything on purpose: a tick, a dot.
  if (length < 24 || diagonal < 16) return null;

  const ends = gap(points[0], points[points.length - 1]);
  // A circle runs about 2.2 times its box's diagonal, a square 2.8, a line 1.
  const closed = ends < 0.25 * diagonal && length > 1.8 * diagonal;
  if (closed) return rectangle(points, bounds, diagonal) ?? ellipse(points, bounds);
  return line(points, length) ?? arrow(points, length, diagonal);
}

/** Nearly as long end to end as along the way, and never far off the chord. */
function line(points: P[], length: number): Shape | null {
  const start = points[0];
  const end = points[points.length - 1];
  const chord = gap(start, end);
  if (chord / length <= 0.9) return null;
  const deviation = Math.max(...points.map((p) => distanceToSegment(p, start, end)));
  if (deviation >= Math.max(5, 0.08 * chord)) return null;
  return { kind: "line", start, end };
}

/** Every point close to the ellipse inscribed in the box, most of the way round. */
function ellipse(points: P[], bounds: Box): Shape | null {
  const rx = bounds.width / 2;
  const ry = bounds.height / 2;
  if (rx <= 4 || ry <= 4) return null;
  const cx = bounds.x + rx;
  const cy = bounds.y + ry;
  const errors: number[] = [];
  const angles: number[] = [];
  for (const p of points) {
    const nx = (p.x - cx) / rx;
    const ny = (p.y - cy) / ry;
    errors.push(Math.abs(Math.hypot(nx, ny) - 1));
    angles.push(Math.atan2(ny, nx));
  }
  const mean = errors.reduce((a, b) => a + b, 0) / errors.length;
  if (mean >= 0.11 || Math.max(...errors) >= 0.35) return null;
  if (sweep(angles) <= 1.75 * Math.PI) return null;
  return { kind: "ellipse", rect: bounds };
}

function sweep(angles: number[]): number {
  let total = 0;
  for (let i = 1; i < angles.length; i++) {
    let step = angles[i] - angles[i - 1];
    if (step > Math.PI) step -= 2 * Math.PI;
    if (step < -Math.PI) step += 2 * Math.PI;
    total += step;
  }
  return Math.abs(total);
}

/** Four sharp corners near the box's corners, every point hugging one of its edges. */
function rectangle(points: P[], bounds: Box, diagonal: number): Shape | null {
  if (bounds.width <= 8 || bounds.height <= 8) return null;
  const minX = bounds.x, maxX = bounds.x + bounds.width, minY = bounds.y, maxY = bounds.y + bounds.height;
  const tolerance = Math.max(6, 0.09 * Math.min(bounds.width, bounds.height) + 0.03 * diagonal);
  let offEdge = 0;
  let total = 0;
  for (const p of points) {
    const d = Math.min(Math.abs(p.x - minX), Math.abs(p.x - maxX), Math.abs(p.y - minY), Math.abs(p.y - maxY));
    total += d;
    if (d > tolerance) offEdge++;
  }
  if (offEdge / points.length >= 0.06 || total / points.length >= tolerance * 0.5) return null;

  // An ellipse hugs its box only at four points; a rectangle reaches every corner.
  const corners = [{ x: minX, y: minY }, { x: maxX, y: minY }, { x: maxX, y: maxY }, { x: minX, y: maxY }];
  const reach = Math.max(8, 0.16 * Math.min(bounds.width, bounds.height));
  for (const corner of corners) {
    if (Math.min(...points.map((p) => gap(p, corner))) >= reach) return null;
  }
  return { kind: "rectangle", rect: bounds };
}

/** A long straight shaft, then a short head drawn back from its tip. */
function arrow(points: P[], length: number, diagonal: number): Shape | null {
  const cornerIndices = simplify(points, Math.max(4, 0.05 * diagonal));
  const corners = cornerIndices.map((i) => points[i]);
  if (corners.length < 3) return null;

  for (let tipIndex = 1; tipIndex < corners.length - 1; tipIndex++) {
    const start = corners[0];
    const tip = corners[tipIndex];
    const shaft = gap(start, tip);
    if (shaft <= 0.45 * length) continue;
    const tipInPoints = cornerIndices[tipIndex];
    const deviation = Math.max(...points.slice(0, tipInPoints + 1).map((p) => distanceToSegment(p, start, tip)));
    if (deviation >= Math.max(6, 0.1 * shaft)) continue;

    const head = corners.slice(tipIndex + 1);
    if (!head.every((c) => gap(c, tip) < 0.5 * shaft)) continue;
    const back = { x: start.x - tip.x, y: start.y - tip.y };
    const barbs = head.filter((corner) => {
      const barb = { x: corner.x - tip.x, y: corner.y - tip.y };
      if (Math.hypot(barb.x, barb.y) <= Math.max(5, 0.08 * shaft)) return false;
      const angle = angleBetween(back, barb);
      return angle > Math.PI / 14 && angle < Math.PI * 0.45;
    });
    if (barbs.length === 0) continue;
    return { kind: "arrow", start, end: tip };
  }
  return null;
}

function dedupe(points: P[]): P[] {
  const out: P[] = [];
  for (const p of points) if (out.length === 0 || gap(out[out.length - 1], p) > 0.5) out.push(p);
  return out;
}

function pathLength(points: P[]): number {
  let total = 0;
  for (let i = 1; i < points.length; i++) total += gap(points[i - 1], points[i]);
  return total;
}

function boundingBox(points: P[]): Box {
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const x = Math.min(...xs);
  const y = Math.min(...ys);
  return { x, y, width: Math.max(...xs) - x, height: Math.max(...ys) - y };
}

export function distanceToSegment(p: P, a: P, b: P): number {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSquared = dx * dx + dy * dy;
  if (lengthSquared === 0) return gap(p, a);
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared));
  return gap(p, { x: a.x + t * dx, y: a.y + t * dy });
}

function angleBetween(a: P, b: P): number {
  const sizes = Math.hypot(a.x, a.y) * Math.hypot(b.x, b.y);
  if (sizes === 0) return Math.PI;
  return Math.acos(Math.max(-1, Math.min(1, (a.x * b.x + a.y * b.y) / sizes)));
}

/** Ramer–Douglas–Peucker: the indices of the corners that matter. */
export function simplify(points: P[], tolerance: number): number[] {
  if (points.length <= 2) return points.map((_, i) => i);
  const keep = new Array(points.length).fill(false);
  keep[0] = keep[points.length - 1] = true;
  const stack: [number, number][] = [[0, points.length - 1]];
  while (stack.length) {
    const [first, last] = stack.pop()!;
    if (last <= first + 1) continue;
    let farthest = first;
    let farthestDistance = 0;
    for (let i = first + 1; i < last; i++) {
      const d = distanceToSegment(points[i], points[first], points[last]);
      if (d > farthestDistance) {
        farthest = i;
        farthestDistance = d;
      }
    }
    if (farthestDistance > tolerance) {
      keep[farthest] = true;
      stack.push([first, farthest], [farthest, last]);
    }
  }
  return keep.flatMap((k, i) => (k ? [i] : []));
}
