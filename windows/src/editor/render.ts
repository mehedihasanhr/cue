// Draws a document onto a 2D canvas whose units are output points (origin top left).
// The editor's canvas and the exporter both call this, so what is shown is exactly what
// is exported. Ported from the Mac's `AnnotationRenderer.swift`.

import { arrowGeometry, bounds, canRotate, center, fontFor, TEXT_PADDING, textSize } from "./model/geometry";
import { contentOffset, contentRect, GRADIENTS, layout, type Background, type Doc } from "./model/document";
import { css, isLight, type Annotation, type Point, type Rect, type ShapeStyle, type StrokeStyle } from "./model/types";

type Ctx = CanvasRenderingContext2D;

export type Source = {
  image: HTMLImageElement;
  /** The image's own edge colour, for the inset border. */
  edgeColor: string;
};

export type DrawOptions = {
  draft?: Annotation | null;
  /** A text box being typed into: its box is drawn, its words are left to the editor on top. */
  editingTextId?: string | null;
  /** Draw the whole image and ignore the crop (the crop tool shows what is outside it). */
  ignoreCrop?: boolean;
};

export function draw(ctx: Ctx, doc: Doc, source: Source, options: DrawOptions = {}) {
  const shown = options.ignoreCrop ? { ...doc, crop: null, background: null } : doc;
  const l = layout(shown);
  if (shown.background) drawBackground(ctx, shown.background, l.width, l.height, l.card);
  drawContent(ctx, shown, source);
  ctx.save();
  ctx.beginPath();
  ctx.rect(0, 0, l.width, l.height);
  ctx.clip();
  const offset = contentOffset(shown);
  ctx.translate(offset.x, offset.y);
  for (const annotation of doc.annotations) {
    drawAnnotation(ctx, annotation, shown, source, annotation.id !== options.editingTextId);
  }
  if (options.draft) drawAnnotation(ctx, options.draft, shown, source, true);
  ctx.restore();
}

function roundRect(ctx: Ctx, r: Rect, radius: number) {
  ctx.beginPath();
  ctx.roundRect(r.x, r.y, r.width, r.height, Math.max(0, Math.min(radius, r.width / 2, r.height / 2)));
}

function drawBackground(ctx: Ctx, style: Background, width: number, height: number, card: Rect) {
  if (style.fill.type === "solid") {
    ctx.fillStyle = css(style.fill.color);
  } else {
    const stops = GRADIENTS[style.fill.name];
    const radians = (style.gradientAngle * Math.PI) / 180;
    const half = { x: (Math.sin(radians) * width) / 2, y: (Math.cos(radians) * height) / 2 };
    const gradient = ctx.createLinearGradient(width / 2 - half.x, height / 2 - half.y, width / 2 + half.x, height / 2 + half.y);
    stops.forEach((stop, i) => gradient.addColorStop(i / Math.max(1, stops.length - 1), css(stop)));
    ctx.fillStyle = gradient;
  }
  ctx.fillRect(0, 0, width, height);

  if (style.shadow > 0.01) {
    // Soft and wide rather than dark. Canvas takes shadow sizes in device pixels, so
    // they are scaled by the current transform to stay in points.
    const strength = Math.min(1, Math.max(0, style.shadow));
    const device = ctx.getTransform().a;
    ctx.save();
    ctx.shadowColor = `rgba(0,0,0,${0.08 + 0.32 * strength})`;
    ctx.shadowBlur = (10 + 30 * strength) * device;
    ctx.shadowOffsetY = (2 + 7 * strength) * device;
    ctx.fillStyle = "#000";
    roundRect(ctx, card, style.cornerRadius);
    ctx.fill();
    ctx.restore();
  }
}

function drawContent(ctx: Ctx, doc: Doc, source: Source) {
  const l = layout(doc);
  const background = doc.background;
  if (background && background.inset > 0) {
    ctx.fillStyle = source.edgeColor;
    roundRect(ctx, l.card, background.cornerRadius);
    ctx.fill();
  }
  ctx.save();
  if (background && background.cornerRadius > 0) {
    roundRect(ctx, l.image, Math.max(0, background.cornerRadius - background.inset));
  } else {
    ctx.beginPath();
    ctx.rect(l.image.x, l.image.y, l.image.width, l.image.height);
  }
  ctx.clip();
  const offset = contentOffset(doc);
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(source.image, offset.x, offset.y, doc.width, doc.height);
  ctx.restore();
}

function drawAnnotation(ctx: Ctx, a: Annotation, doc: Doc, source: Source, drawsText: boolean) {
  ctx.save();
  if (a.rotation && canRotate(a)) {
    const c = center(a);
    ctx.translate(c.x, c.y);
    ctx.rotate(a.rotation);
    ctx.translate(-c.x, -c.y);
  }
  drawUnrotated(ctx, a, doc, source, drawsText);
  ctx.restore();
}

function applyStroke(ctx: Ctx, style: StrokeStyle, alpha?: number) {
  ctx.strokeStyle = css(style.color, alpha);
  ctx.lineWidth = style.width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
}

function fillAndStroke(ctx: Ctx, path: Path2D, style: ShapeStyle) {
  if (style.fill !== "none") {
    ctx.fillStyle = css(style.stroke.color, style.fill === "solid" ? 1 : 0.3);
    ctx.fill(path);
  }
  if (style.stroke.width > 0) {
    applyStroke(ctx, style.stroke);
    ctx.stroke(path);
  }
}

function drawUnrotated(ctx: Ctx, a: Annotation, doc: Doc, source: Source, drawsText: boolean) {
  switch (a.type) {
    case "rectangle": {
      const path = new Path2D();
      path.rect(a.rect.x, a.rect.y, a.rect.width, a.rect.height);
      return fillAndStroke(ctx, path, a.style);
    }
    case "ellipse": {
      const path = new Path2D();
      const r = a.rect;
      path.ellipse(r.x + r.width / 2, r.y + r.height / 2, r.width / 2, r.height / 2, 0, 0, Math.PI * 2);
      return fillAndStroke(ctx, path, a.style);
    }
    case "line":
      applyStroke(ctx, a.style);
      ctx.beginPath();
      ctx.moveTo(a.start.x, a.start.y);
      ctx.lineTo(a.end.x, a.end.y);
      return ctx.stroke();
    case "arrow":
      return drawArrow(ctx, a);
    case "pencil":
      applyStroke(ctx, a.style);
      ctx.stroke(smoothPath(a.points));
      return;
    case "highlighter":
      ctx.globalCompositeOperation = "multiply";
      applyStroke(ctx, a.style, 0.45);
      ctx.lineCap = "square";
      ctx.stroke(polyline(a.points));
      return;
    case "highlight":
      ctx.globalCompositeOperation = "multiply";
      ctx.fillStyle = css(a.color, 0.45);
      roundRect(ctx, a.rect, 3);
      return ctx.fill();
    case "text":
      return drawText(ctx, a, drawsText);
    case "counter":
      return drawCounter(ctx, a);
    case "blur":
      return drawBlur(ctx, a, doc, source);
  }
}

function drawArrow(ctx: Ctx, a: Extract<Annotation, { type: "arrow" }>) {
  const { start, end, bend, style } = a;
  if (Math.hypot(end.x - start.x, end.y - start.y) <= 0.5) return;
  const headLength = Math.max(12, style.width * 4);
  const headWidth = headLength * 0.9;
  const endDirection = arrowGeometry.tangent(1, start, end, bend);
  const startDirection = arrowGeometry.tangent(0, start, end, bend);
  const head = (tip: Point, dir: Point) => {
    const normal = { x: -dir.y, y: dir.x };
    const base = { x: tip.x - dir.x * headLength, y: tip.y - dir.y * headLength };
    const path = new Path2D();
    path.moveTo(tip.x, tip.y);
    path.lineTo(base.x + (normal.x * headWidth) / 2, base.y + (normal.y * headWidth) / 2);
    path.lineTo(base.x - (normal.x * headWidth) / 2, base.y - (normal.y * headWidth) / 2);
    path.closePath();
    return path;
  };
  applyStroke(ctx, style);
  ctx.fillStyle = css(style.color);
  // The shaft stops short of each tip so its round cap does not poke out of the head.
  const shaftEnd = { x: end.x - endDirection.x * headLength * 0.8, y: end.y - endDirection.y * headLength * 0.8 };
  const shaftStart =
    a.arrowStyle === "double"
      ? { x: start.x + startDirection.x * headLength * 0.8, y: start.y + startDirection.y * headLength * 0.8 }
      : start;
  ctx.beginPath();
  ctx.moveTo(shaftStart.x, shaftStart.y);
  if (bend.x === 0 && bend.y === 0) ctx.lineTo(shaftEnd.x, shaftEnd.y);
  else {
    const c = arrowGeometry.control(start, end, bend);
    ctx.quadraticCurveTo(c.x, c.y, shaftEnd.x, shaftEnd.y);
  }
  ctx.stroke();
  ctx.fill(head(end, endDirection));
  if (a.arrowStyle === "double") ctx.fill(head(start, { x: -startDirection.x, y: -startDirection.y }));
}

function drawText(ctx: Ctx, a: Extract<Annotation, { type: "text" }>, drawsGlyphs: boolean) {
  const size = textSize(a.text, a.style);
  const box = { ...a.origin, ...size };
  let color = css(a.style.color);
  if (a.style.background === "solid") {
    ctx.fillStyle = css(a.style.color);
    roundRect(ctx, box, 6);
    ctx.fill();
    color = isLight(a.style.color) ? "#000" : "#fff";
  } else if (a.style.background === "translucent") {
    ctx.fillStyle = "rgba(0,0,0,0.6)";
    roundRect(ctx, box, 6);
    ctx.fill();
  } else {
    const device = ctx.getTransform().a;
    ctx.shadowColor = "rgba(0,0,0,0.5)";
    ctx.shadowBlur = 2 * device;
    ctx.shadowOffsetY = 1 * device;
  }
  if (!drawsGlyphs || !a.text) return;
  ctx.font = fontFor(a.style);
  ctx.fillStyle = color;
  ctx.textBaseline = "top";
  const lineHeight = Math.ceil(a.style.fontSize * 1.25);
  const nudge = (lineHeight - a.style.fontSize) / 2;
  a.text.split("\n").forEach((line, i) => {
    ctx.fillText(line, box.x + TEXT_PADDING.width, box.y + TEXT_PADDING.height + nudge + i * lineHeight);
  });
}

function drawCounter(ctx: Ctx, a: Extract<Annotation, { type: "counter" }>) {
  const { center: c, size, color, number } = a;
  const device = ctx.getTransform().a;
  ctx.save();
  ctx.shadowColor = "rgba(0,0,0,0.4)";
  ctx.shadowBlur = 3 * device;
  ctx.shadowOffsetY = 1 * device;
  ctx.fillStyle = css(color);
  ctx.beginPath();
  ctx.arc(c.x, c.y, size / 2, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
  ctx.strokeStyle = "rgba(255,255,255,0.9)";
  ctx.lineWidth = Math.max(1.5, size * 0.06);
  ctx.beginPath();
  ctx.arc(c.x, c.y, size / 2 - 1, 0, Math.PI * 2);
  ctx.stroke();
  ctx.fillStyle = isLight(color) ? "#000" : "#fff";
  ctx.font = `700 ${size * 0.52}px "Segoe UI Variable Text", "Segoe UI", sans-serif`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(String(number), c.x, c.y + size * 0.03);
}

// MARK: - Blur and pixelate: re-sample the image, so they never spill past it.

const effectCache = new Map<string, HTMLCanvasElement>();

function drawBlur(ctx: Ctx, a: Extract<Annotation, { type: "blur" }>, doc: Doc, source: Source) {
  const content = contentRect(doc);
  const r = a.rect;
  if (r.width < 1 || r.height < 1) return;
  const key = `${source.image.src}|${r.x},${r.y},${r.width},${r.height}|${a.kind}|${a.intensity}|${doc.scale}`;
  let effect = effectCache.get(key);
  if (!effect) {
    effect = renderEffect(source.image, r, a.kind, a.intensity, doc.scale);
    if (effectCache.size > 64) effectCache.clear();
    effectCache.set(key, effect);
  }
  ctx.save();
  ctx.beginPath();
  ctx.rect(content.x, content.y, content.width, content.height);
  ctx.clip();
  ctx.imageSmoothingEnabled = a.kind === "blur";
  ctx.drawImage(effect, r.x, r.y, r.width, r.height);
  ctx.restore();
}

function renderEffect(image: HTMLImageElement, r: Rect, kind: "blur" | "pixelate", intensity: number, scale: number) {
  const sx = r.x * scale, sy = r.y * scale, sw = r.width * scale, sh = r.height * scale;
  const out = document.createElement("canvas");
  if (kind === "pixelate") {
    const block = Math.max(4, intensity * scale);
    out.width = Math.max(1, Math.round(sw / block));
    out.height = Math.max(1, Math.round(sh / block));
    const c = out.getContext("2d")!;
    c.imageSmoothingQuality = "medium";
    c.drawImage(image, sx, sy, sw, sh, 0, 0, out.width, out.height);
    return out;
  }
  // Blur with a margin of real pixels around the area, so its edges do not fade to clear.
  const radius = Math.max(2, intensity * scale);
  const margin = Math.ceil(radius * 2);
  out.width = Math.max(1, Math.round(sw));
  out.height = Math.max(1, Math.round(sh));
  const c = out.getContext("2d")!;
  c.filter = `blur(${radius}px)`;
  c.drawImage(image, sx - margin, sy - margin, sw + margin * 2, sh + margin * 2, -margin, -margin, out.width + margin * 2, out.height + margin * 2);
  return out;
}

// MARK: - Paths

function polyline(points: Point[]): Path2D {
  const path = new Path2D();
  if (!points.length) return path;
  path.moveTo(points[0].x, points[0].y);
  if (points.length === 1) path.lineTo(points[0].x + 0.01, points[0].y);
  for (const p of points.slice(1)) path.lineTo(p.x, p.y);
  return path;
}

/** A Catmull-Rom spline through the points — the pencil's smoothing. */
function smoothPath(points: Point[]): Path2D {
  if (points.length <= 2) return polyline(points);
  const path = new Path2D();
  path.moveTo(points[0].x, points[0].y);
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[Math.max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[Math.min(i + 2, points.length - 1)];
    path.bezierCurveTo(p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6, p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6, p2.x, p2.y);
  }
  return path;
}

// MARK: - Export

/** The document flattened at its native pixel scale. */
export function renderToCanvas(doc: Doc, source: Source): HTMLCanvasElement {
  const l = layout(doc);
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(l.width * doc.scale));
  canvas.height = Math.max(1, Math.round(l.height * doc.scale));
  const ctx = canvas.getContext("2d")!;
  ctx.scale(doc.scale, doc.scale);
  draw(ctx, doc, source);
  return canvas;
}

export async function encode(canvas: HTMLCanvasElement, type: "image/png" | "image/jpeg"): Promise<Uint8Array> {
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("Could not encode the image"))), type, 0.9),
  );
  return new Uint8Array(await blob.arrayBuffer());
}

/** The average colour along the image's edges, for the inset border. */
export function edgeColor(image: HTMLImageElement): string {
  const canvas = document.createElement("canvas");
  canvas.width = 32;
  canvas.height = 32;
  const c = canvas.getContext("2d", { willReadFrequently: true })!;
  c.drawImage(image, 0, 0, 32, 32);
  const data = c.getImageData(0, 0, 32, 32).data;
  let r = 0, g = 0, b = 0, n = 0;
  for (let y = 0; y < 32; y++) {
    for (let x = 0; x < 32; x++) {
      if (x !== 0 && y !== 0 && x !== 31 && y !== 31) continue;
      const i = (y * 32 + x) * 4;
      r += data[i]; g += data[i + 1]; b += data[i + 2]; n++;
    }
  }
  return `rgb(${Math.round(r / n)}, ${Math.round(g / n)}, ${Math.round(b / n)})`;
}

export { bounds };
