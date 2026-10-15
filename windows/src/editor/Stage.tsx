// The editor's canvas: draws the document and turns the pointer into annotations.
//
// The document is in image points. The view maps output points (the image plus any
// background) to the stage with `zoom` and `origin`; image points are output points less
// the content offset, which the crop and the background move.

import { forwardRef, useEffect, useImperativeHandle, useLayoutEffect, useRef, useState } from "react";
import {
  arrowGeometry, bounds, canRotate, center, constrain45, constrainSquare, hasEndpoints, hits, isResizable, localPoint,
  moved, rectFrom, rotate, TEXT_PADDING, textSize, withEndpoints, withRect, worldPoint,
} from "./model/geometry";
import { contentOffset, layout, type Doc } from "./model/document";
import { recognize } from "./model/shapeRecognizer";
import { css, isLight, type Annotation, type Point, type Rect } from "./model/types";
import type { Prefs, Tool } from "./prefs";
import { draw, type Source } from "./render";

type Handle = "nw" | "n" | "ne" | "e" | "se" | "s" | "sw" | "w";
const HANDLES: Handle[] = ["nw", "n", "ne", "e", "se", "s", "sw", "w"];
const HANDLE_RADIUS = 7; // CSS pixels

type Drag =
  | { kind: "draw"; anchor: Point; points: Point[] }
  | { kind: "move"; start: Point; original: Annotation }
  | { kind: "resize"; handle: Handle; original: Annotation }
  | { kind: "endpoint"; which: "start" | "end" | "bend"; original: Annotation }
  | { kind: "rotate"; original: Annotation; startAngle: number }
  | { kind: "cropNew"; anchor: Point }
  | { kind: "cropMove"; start: Point; original: Rect }
  | { kind: "cropResize"; handle: Handle; original: Rect }
  | { kind: "pan"; start: Point; origin: Point };

export type StageHandle = {
  fit: () => void;
  zoomBy: (factor: number) => void;
  actualSize: () => void;
  cropRect: () => Rect;
};

type Props = {
  doc: Doc;
  source: Source;
  tool: Tool;
  prefs: Prefs;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  /** A finished change, for the undo history. */
  onCommit: (doc: Doc) => void;
  onZoomChange: (zoom: number) => void;
};

const uid = () => crypto.randomUUID();

function handlePoint(r: Rect, h: Handle): Point {
  const x = h.includes("w") ? r.x : h.includes("e") ? r.x + r.width : r.x + r.width / 2;
  const y = h.includes("n") ? r.y : h.includes("s") ? r.y + r.height : r.y + r.height / 2;
  return { x, y };
}

const opposite: Record<Handle, Handle> = { nw: "se", n: "s", ne: "sw", e: "w", se: "nw", s: "n", sw: "ne", w: "e" };

/** `r` resized by dragging `h` to `q` (both in the box's own frame). */
function resizeRect(r: Rect, h: Handle, q: Point, keepAspect: boolean): Rect {
  let left = r.x, right = r.x + r.width, top = r.y, bottom = r.y + r.height;
  if (h.includes("w")) left = q.x;
  if (h.includes("e")) right = q.x;
  if (h.includes("n")) top = q.y;
  if (h.includes("s")) bottom = q.y;
  let next = { x: Math.min(left, right), y: Math.min(top, bottom), width: Math.abs(right - left), height: Math.abs(bottom - top) };
  if (keepAspect && h.length === 2 && r.width > 0 && r.height > 0) {
    const ratio = r.width / r.height;
    const fixed = handlePoint(r, opposite[h]);
    if (next.width / next.height > ratio) next.height = next.width / ratio;
    else next.width = next.height * ratio;
    next = {
      ...next,
      x: h.includes("w") ? fixed.x - next.width : fixed.x,
      y: h.includes("n") ? fixed.y - next.height : fixed.y,
    };
  }
  return next;
}

export const Stage = forwardRef<StageHandle, Props>(function Stage(props, ref) {
  const { doc, source, tool, prefs, selectedId, onSelect, onCommit, onZoomChange } = props;
  const host = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [view, setView] = useState<{ zoom: number; origin: Point; fitted: boolean }>({ zoom: 1, origin: { x: 0, y: 0 }, fitted: true });
  const [working, setWorking] = useState<Doc | null>(null);
  const [draft, setDraft] = useState<Annotation | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [crop, setCrop] = useState<Rect | null>(null);
  const [spaceHeld, setSpaceHeld] = useState(false);
  const drag = useRef<Drag | null>(null);

  const current = working ?? doc;
  const cropping = tool === "crop";
  const shown = cropping ? { ...current, crop: null, background: null } : current;
  const out = layout(shown);
  const offset = contentOffset(shown);
  const cropRect = crop ?? doc.crop ?? { x: 0, y: 0, width: doc.width, height: doc.height };

  useEffect(() => {
    if (!cropping) setCrop(null);
  }, [cropping]);

  // MARK: - View

  function fitView(width = size.width, height = size.height) {
    if (!width || !height) return;
    const zoom = Math.min((width - 64) / out.width, (height - 64) / out.height, 2);
    setView({ zoom, origin: { x: (width - out.width * zoom) / 2, y: (height - out.height * zoom) / 2 }, fitted: true });
  }

  function zoomAround(zoom: number, at: Point) {
    const clamped = Math.min(16, Math.max(0.05, zoom));
    setView((v) => ({
      zoom: clamped,
      origin: { x: at.x - ((at.x - v.origin.x) / v.zoom) * clamped, y: at.y - ((at.y - v.origin.y) / v.zoom) * clamped },
      fitted: false,
    }));
  }

  useImperativeHandle(ref, () => ({
    fit: () => fitView(),
    zoomBy: (factor) => zoomAround(view.zoom * factor, { x: size.width / 2, y: size.height / 2 }),
    // 100%: one image pixel to one screen pixel.
    actualSize: () => zoomAround(doc.scale / (window.devicePixelRatio || 1), { x: size.width / 2, y: size.height / 2 }),
    cropRect: () => cropRect,
  }));

  useLayoutEffect(() => {
    const element = host.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      setSize({ width: entry.contentRect.width, height: entry.contentRect.height });
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // Refit while the user has not zoomed by hand: on resize, crop, background.
  useEffect(() => {
    if (view.fitted) fitView();
  }, [size.width, size.height, out.width, out.height]);

  useEffect(() => onZoomChange(view.zoom), [view.zoom]);

  const toScreen = (p: Point): Point => ({
    x: view.origin.x + (p.x + offset.x) * view.zoom,
    y: view.origin.y + (p.y + offset.y) * view.zoom,
  });

  function toImage(event: { clientX: number; clientY: number }): Point {
    const box = canvas.current!.getBoundingClientRect();
    return {
      x: (event.clientX - box.left - view.origin.x) / view.zoom - offset.x,
      y: (event.clientY - box.top - view.origin.y) / view.zoom - offset.y,
    };
  }

  // MARK: - Drawing

  useEffect(() => {
    const element = canvas.current;
    if (!element || !size.width) return;
    const dpr = window.devicePixelRatio || 1;
    element.width = Math.round(size.width * dpr);
    element.height = Math.round(size.height * dpr);
    const ctx = element.getContext("2d")!;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, size.width, size.height);

    ctx.save();
    ctx.translate(view.origin.x, view.origin.y);
    ctx.scale(view.zoom, view.zoom);
    ctx.shadowColor = "rgba(0,0,0,0.18)";
    ctx.shadowBlur = 16 * dpr;
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, out.width, out.height);
    ctx.shadowColor = "transparent";
    ctx.clearRect(0, 0, out.width, out.height);
    draw(ctx, current, source, { draft, editingTextId: editingId, ignoreCrop: cropping });
    ctx.restore();

    if (cropping) drawCropOverlay(ctx);
    else drawSelection(ctx);
  });

  function drawSelection(ctx: CanvasRenderingContext2D) {
    const selected = current.annotations.find((a) => a.id === selectedId);
    if (!selected || editingId === selected.id) return;
    ctx.save();
    ctx.strokeStyle = "#2e6bff";
    ctx.fillStyle = "#fff";
    ctx.lineWidth = 1.5;
    if (hasEndpoints(selected) && (selected.type === "line" || selected.type === "arrow")) {
      const points = [selected.start, selected.end];
      if (selected.type === "arrow") points.push(arrowGeometry.handle(selected.start, selected.end, selected.bend));
      points.forEach((p, i) => dot(ctx, toScreen(p), i === 2));
      ctx.restore();
      return;
    }
    const b = bounds(selected);
    const corners = [handlePoint(b, "nw"), handlePoint(b, "ne"), handlePoint(b, "se"), handlePoint(b, "sw")]
      .map((p) => toScreen(worldPoint(selected, p)));
    ctx.setLineDash([4, 3]);
    ctx.beginPath();
    corners.forEach((p, i) => (i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)));
    ctx.closePath();
    ctx.stroke();
    ctx.setLineDash([]);
    if (isResizable(selected)) HANDLES.forEach((h) => square(ctx, toScreen(worldPoint(selected, handlePoint(b, h)))));
    if (canRotate(selected)) {
      const knob = rotationKnob(selected);
      const top = toScreen(worldPoint(selected, handlePoint(b, "n")));
      ctx.beginPath();
      ctx.moveTo(top.x, top.y);
      ctx.lineTo(knob.x, knob.y);
      ctx.stroke();
      dot(ctx, knob, true);
    }
    ctx.restore();
  }

  function drawCropOverlay(ctx: CanvasRenderingContext2D) {
    const image = { ...toScreen({ x: 0, y: 0 }), width: doc.width * view.zoom, height: doc.height * view.zoom };
    const r = { ...toScreen(cropRect), width: cropRect.width * view.zoom, height: cropRect.height * view.zoom };
    ctx.save();
    ctx.fillStyle = "rgba(0,0,0,0.5)";
    ctx.beginPath();
    ctx.rect(image.x, image.y, image.width, image.height);
    ctx.rect(r.x, r.y, r.width, r.height);
    ctx.fill("evenodd");
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 1.5;
    ctx.strokeRect(r.x, r.y, r.width, r.height);
    ctx.strokeStyle = "rgba(255,255,255,0.35)";
    ctx.lineWidth = 1;
    for (const t of [1 / 3, 2 / 3]) {
      ctx.beginPath();
      ctx.moveTo(r.x + r.width * t, r.y);
      ctx.lineTo(r.x + r.width * t, r.y + r.height);
      ctx.moveTo(r.x, r.y + r.height * t);
      ctx.lineTo(r.x + r.width, r.y + r.height * t);
      ctx.stroke();
    }
    ctx.strokeStyle = "#2e6bff";
    ctx.fillStyle = "#fff";
    HANDLES.forEach((h) => square(ctx, toScreen(handlePoint(cropRect, h))));
    ctx.restore();
  }

  function square(ctx: CanvasRenderingContext2D, p: Point) {
    ctx.beginPath();
    ctx.rect(p.x - 4.5, p.y - 4.5, 9, 9);
    ctx.fill();
    ctx.stroke();
  }

  function dot(ctx: CanvasRenderingContext2D, p: Point, accent = false) {
    ctx.beginPath();
    ctx.arc(p.x, p.y, 5.5, 0, Math.PI * 2);
    ctx.fillStyle = accent ? "#2e6bff" : "#fff";
    ctx.fill();
    ctx.strokeStyle = accent ? "#fff" : "#2e6bff";
    ctx.stroke();
    ctx.fillStyle = "#fff";
    ctx.strokeStyle = "#2e6bff";
  }

  /** The rotation knob, 24 CSS pixels above the box's top edge, on screen. */
  function rotationKnob(a: Annotation): Point {
    const b = bounds(a);
    const up = rotate({ x: 0, y: -24 }, a.rotation, { x: 0, y: 0 });
    const top = toScreen(worldPoint(a, handlePoint(b, "n")));
    return { x: top.x + up.x, y: top.y + up.y };
  }

  // MARK: - Hit testing (screen distances in CSS pixels)

  function screenDistance(a: Point, b: Point) {
    const sa = toScreen(a);
    return Math.hypot(sa.x - b.x, sa.y - b.y);
  }

  function handleAt(screen: Point): Drag | null {
    const selected = current.annotations.find((a) => a.id === selectedId);
    if (!selected) return null;
    if (selected.type === "line" || selected.type === "arrow") {
      const ends: ["start" | "end" | "bend", Point][] = [["start", selected.start], ["end", selected.end]];
      if (selected.type === "arrow") ends.push(["bend", arrowGeometry.handle(selected.start, selected.end, selected.bend)]);
      for (const [which, p] of ends) {
        if (screenDistance(p, screen) <= HANDLE_RADIUS + 2) return { kind: "endpoint", which, original: selected };
      }
      return null;
    }
    if (canRotate(selected)) {
      const knob = rotationKnob(selected);
      if (Math.hypot(knob.x - screen.x, knob.y - screen.y) <= HANDLE_RADIUS + 2) {
        const c = center(selected);
        const p = screenToImage(screen);
        return { kind: "rotate", original: selected, startAngle: Math.atan2(p.y - c.y, p.x - c.x) };
      }
    }
    if (isResizable(selected)) {
      const b = bounds(selected);
      for (const h of HANDLES) {
        if (screenDistance(worldPoint(selected, handlePoint(b, h)), screen) <= HANDLE_RADIUS) {
          return { kind: "resize", handle: h, original: selected };
        }
      }
    }
    return null;
  }

  function screenToImage(screen: Point): Point {
    return { x: (screen.x - view.origin.x) / view.zoom - offset.x, y: (screen.y - view.origin.y) / view.zoom - offset.y };
  }

  function annotationAt(p: Point): Annotation | null {
    const slop = 6 / view.zoom;
    for (let i = current.annotations.length - 1; i >= 0; i--) {
      if (hits(current.annotations[i], p, slop)) return current.annotations[i];
    }
    return null;
  }

  // MARK: - Pointer

  function screenPoint(event: React.PointerEvent): Point {
    const box = canvas.current!.getBoundingClientRect();
    return { x: event.clientX - box.left, y: event.clientY - box.top };
  }

  function replace(a: Annotation) {
    setWorking({ ...current, annotations: current.annotations.map((x) => (x.id === a.id ? a : x)) });
  }

  function onPointerDown(event: React.PointerEvent) {
    if (editingId) return; // the text box's blur commits it first
    const screen = screenPoint(event);
    const p = toImage(event);
    (event.target as Element).setPointerCapture(event.pointerId);

    if (event.button === 1 || spaceHeld) {
      drag.current = { kind: "pan", start: screen, origin: view.origin };
      return;
    }
    if (event.button !== 0) return;

    if (cropping) {
      for (const h of HANDLES) {
        if (screenDistance(handlePoint(cropRect, h), screen) <= HANDLE_RADIUS) {
          drag.current = { kind: "cropResize", handle: h, original: cropRect };
          return;
        }
      }
      const inside = p.x >= cropRect.x && p.x <= cropRect.x + cropRect.width && p.y >= cropRect.y && p.y <= cropRect.y + cropRect.height;
      drag.current = inside ? { kind: "cropMove", start: p, original: cropRect } : { kind: "cropNew", anchor: p };
      return;
    }

    const handle = handleAt(screen);
    if (handle) {
      drag.current = handle;
      return;
    }

    if (tool === "select") {
      const hit = annotationAt(p);
      onSelect(hit?.id ?? null);
      if (hit) {
        if (event.detail === 2 && hit.type === "text") return setEditingId(hit.id);
        drag.current = { kind: "move", start: p, original: hit };
      }
      return;
    }

    if (tool === "text") {
      const hit = annotationAt(p);
      if (hit?.type === "text") {
        onSelect(hit.id);
        return setEditingId(hit.id);
      }
      const text: Annotation = {
        id: uid(), rotation: 0, type: "text", text: "",
        origin: { x: p.x - TEXT_PADDING.width, y: p.y - prefs.fontSize * 0.75 },
        style: { color: prefs.color, fontSize: prefs.fontSize, weight: prefs.fontWeight, background: prefs.textBackground },
      };
      setWorking({ ...current, annotations: [...current.annotations, text] });
      onSelect(text.id);
      return setEditingId(text.id);
    }

    if (tool === "counter") {
      const counter: Annotation = {
        id: uid(), rotation: 0, type: "counter", center: p, number: current.nextCounter, color: prefs.color, size: prefs.counterSize,
      };
      onCommit({ ...current, annotations: [...current.annotations, counter], nextCounter: current.nextCounter + 1 });
      onSelect(counter.id);
      return;
    }

    onSelect(null);
    drag.current = { kind: "draw", anchor: p, points: [p] };
  }

  function onPointerMove(event: React.PointerEvent) {
    const d = drag.current;
    if (!d) return;
    const p = toImage(event);
    switch (d.kind) {
      case "pan": {
        const screen = screenPoint(event);
        setView({ zoom: view.zoom, origin: { x: d.origin.x + screen.x - d.start.x, y: d.origin.y + screen.y - d.start.y }, fitted: false });
        return;
      }
      case "draw":
        d.points.push(p);
        return setDraft(makeDraft(d.anchor, p, d.points, event.shiftKey));
      case "move":
        return replace(moved(d.original, { x: p.x - d.start.x, y: p.y - d.start.y }));
      case "resize": {
        const a = d.original;
        const r = bounds(a);
        const q = localPoint(a, p);
        const next = resizeRect(r, d.handle, q, event.shiftKey);
        if (!a.rotation) return replace(withRect(a, next));
        // Keep the opposite handle where it is on screen while the box turns about a new centre.
        const fixedLocal = handlePoint(r, opposite[d.handle]);
        const fixedWorld = worldPoint(a, fixedLocal);
        const nextFixed = handlePoint(next, opposite[d.handle]);
        const nextCenter = { x: next.x + next.width / 2, y: next.y + next.height / 2 };
        const v = rotate({ x: nextFixed.x - nextCenter.x, y: nextFixed.y - nextCenter.y }, a.rotation, { x: 0, y: 0 });
        const c = { x: fixedWorld.x - v.x, y: fixedWorld.y - v.y };
        return replace(withRect(a, { ...next, x: c.x - next.width / 2, y: c.y - next.height / 2 }));
      }
      case "endpoint": {
        const a = d.original;
        if (a.type !== "line" && a.type !== "arrow") return;
        if (d.which === "bend" && a.type === "arrow") {
          return replace({ ...a, bend: arrowGeometry.bendFor(p, a.start, a.end) });
        }
        const other = d.which === "start" ? a.end : a.start;
        const q = event.shiftKey ? constrain45(other, p) : p;
        return replace(d.which === "start" ? withEndpoints(a, q, a.end) : withEndpoints(a, a.start, q));
      }
      case "rotate": {
        const c = center(d.original);
        let angle = d.original.rotation + Math.atan2(p.y - c.y, p.x - c.x) - d.startAngle;
        if (event.shiftKey) angle = Math.round(angle / (Math.PI / 12)) * (Math.PI / 12);
        return replace({ ...d.original, rotation: angle });
      }
      case "cropNew":
        return setCrop(clampToImage(rectFrom(d.anchor, event.shiftKey ? constrainSquare(d.anchor, p) : p)));
      case "cropMove": {
        const r = d.original;
        const x = Math.min(Math.max(0, r.x + p.x - d.start.x), doc.width - r.width);
        const y = Math.min(Math.max(0, r.y + p.y - d.start.y), doc.height - r.height);
        return setCrop({ ...r, x, y });
      }
      case "cropResize":
        return setCrop(clampToImage(resizeRect(d.original, d.handle, p, event.shiftKey)));
    }
  }

  function clampToImage(r: Rect): Rect {
    const x = Math.max(0, r.x), y = Math.max(0, r.y);
    return {
      x: Math.round(x), y: Math.round(y),
      width: Math.round(Math.min(doc.width, r.x + r.width) - x),
      height: Math.round(Math.min(doc.height, r.y + r.height) - y),
    };
  }

  function makeDraft(anchor: Point, p: Point, points: Point[], shift: boolean): Annotation | null {
    const id = "draft";
    const stroke = { color: prefs.color, width: prefs.strokeWidth };
    switch (tool) {
      case "shape": {
        if (prefs.shapeKind === "line") {
          return { id, rotation: 0, type: "line", start: anchor, end: shift ? constrain45(anchor, p) : p, style: stroke };
        }
        const rect = rectFrom(anchor, shift ? constrainSquare(anchor, p) : p);
        return { id, rotation: 0, type: prefs.shapeKind, rect, style: { stroke, fill: prefs.fill } };
      }
      case "arrow":
        return { id, rotation: 0, type: "arrow", start: anchor, end: shift ? constrain45(anchor, p) : p, bend: { x: 0, y: 0 }, style: stroke, arrowStyle: prefs.arrowStyle };
      case "pencil":
        return { id, rotation: 0, type: "pencil", points: [...points], style: stroke };
      case "highlighter": {
        // Shift keeps a highlighter stroke level, as a marker run along a line of text.
        const level = shift ? points.map((q) => ({ x: q.x, y: anchor.y })) : [...points];
        return { id, rotation: 0, type: "highlighter", points: level, style: { color: prefs.highlightColor, width: prefs.highlighterWidth } };
      }
      case "highlight":
        return { id, rotation: 0, type: "highlight", rect: rectFrom(anchor, p), color: prefs.highlightColor };
      case "blur":
        return { id, rotation: 0, type: "blur", rect: rectFrom(anchor, shift ? constrainSquare(anchor, p) : p), kind: prefs.blurKind, intensity: prefs.blurIntensity };
      default:
        return null;
    }
  }

  function onPointerUp() {
    const d = drag.current;
    drag.current = null;
    if (!d) return;
    if (d.kind === "draw") {
      let finished = draft;
      setDraft(null);
      if (!finished) return;
      const b = bounds(finished);
      const tiny = Math.max(b.width, b.height) < 3;
      if (tiny && finished.type !== "pencil") return;
      if (finished.type === "pencil" && prefs.smartShapes) finished = smarten(finished) ?? finished;
      const placed = { ...finished, id: uid() } as Annotation;
      onCommit({ ...current, annotations: [...current.annotations, placed] });
      onSelect(placed.id);
      return;
    }
    if (working && ["move", "resize", "endpoint", "rotate"].includes(d.kind)) {
      onCommit(working);
      setWorking(null);
    }
  }

  /** A pencil stroke recognised as the shape it was meant to be, in the pencil's style. */
  function smarten(a: Extract<Annotation, { type: "pencil" }>): Annotation | null {
    const shape = recognize(a.points);
    if (!shape) return null;
    switch (shape.kind) {
      case "line": return { id: a.id, rotation: 0, type: "line", start: shape.start, end: shape.end, style: a.style };
      case "arrow": return { id: a.id, rotation: 0, type: "arrow", start: shape.start, end: shape.end, bend: { x: 0, y: 0 }, style: a.style, arrowStyle: prefs.arrowStyle };
      case "rectangle": return { id: a.id, rotation: 0, type: "rectangle", rect: shape.rect, style: { stroke: a.style, fill: "none" } };
      case "ellipse": return { id: a.id, rotation: 0, type: "ellipse", rect: shape.rect, style: { stroke: a.style, fill: "none" } };
    }
  }

  // MARK: - Wheel and keys

  function onWheel(event: React.WheelEvent) {
    const box = canvas.current!.getBoundingClientRect();
    if (event.ctrlKey) {
      zoomAround(view.zoom * Math.exp(-event.deltaY * 0.0015), { x: event.clientX - box.left, y: event.clientY - box.top });
    } else {
      setView((v) => ({ ...v, origin: { x: v.origin.x - event.deltaX, y: v.origin.y - event.deltaY }, fitted: false }));
    }
  }

  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.code === "Space" && !editingId && !(e.target instanceof HTMLTextAreaElement)) {
        setSpaceHeld(true);
        e.preventDefault();
      }
    };
    const up = (e: KeyboardEvent) => e.code === "Space" && setSpaceHeld(false);
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
    };
  }, [editingId]);

  // MARK: - Text editing

  const editing = current.annotations.find((a) => a.id === editingId);

  function finishEditing() {
    if (!editing || editing.type !== "text") return setEditingId(null);
    const annotations = editing.text.trim()
      ? current.annotations
      : current.annotations.filter((a) => a.id !== editing.id);
    setEditingId(null);
    setWorking(null);
    onCommit({ ...current, annotations });
    if (!editing.text.trim()) onSelect(null);
  }

  let textBox: React.ReactNode = null;
  if (editing && editing.type === "text") {
    const size = textSize(editing.text, editing.style);
    const at = toScreen(editing.origin);
    const z = view.zoom;
    const color = editing.style.background === "solid" ? (isLight(editing.style.color) ? "#000" : "#fff") : css(editing.style.color);
    const lineHeight = Math.ceil(editing.style.fontSize * 1.25);
    textBox = (
      <textarea
        className="text-editor"
        autoFocus
        spellCheck={false}
        value={editing.text}
        placeholder="Text"
        onChange={(e) => replace({ ...editing, text: e.target.value })}
        onBlur={finishEditing}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Escape" || (e.key === "Enter" && e.ctrlKey)) (e.target as HTMLTextAreaElement).blur();
        }}
        style={{
          left: at.x,
          top: at.y,
          width: (size.width + 40) * z,
          height: size.height * z,
          padding: `${TEXT_PADDING.height * z}px ${TEXT_PADDING.width * z}px`,
          font: `${editing.style.weight} ${editing.style.fontSize * z}px "Segoe UI Variable Text", "Segoe UI", sans-serif`,
          lineHeight: `${lineHeight * z}px`,
          color,
          transform: editing.rotation ? `rotate(${editing.rotation}rad)` : undefined,
          transformOrigin: `${(size.width / 2) * z}px ${(size.height / 2) * z}px`,
        }}
      />
    );
  }

  const cursor = spaceHeld ? "grab" : cropping ? "crosshair" : tool === "select" ? "default" : tool === "text" ? "text" : "crosshair";

  return (
    <div ref={host} className="stage" onWheel={onWheel}>
      <canvas
        ref={canvas}
        style={{ width: size.width, height: size.height, cursor }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
        onContextMenu={(e) => e.preventDefault()}
      />
      {textBox}
    </div>
  );
});
