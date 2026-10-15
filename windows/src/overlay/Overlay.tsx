// One display's capture overlay: the frozen picture, dimmed, with the area or window
// being chosen cut out of the dim. Drawn on a canvas the size of the display in physical
// pixels, so every coordinate here is a screen pixel and nothing is rounded twice.

import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useRef, useState } from "react";
import { ipc, type OverlayInfo } from "../lib/ipc";
import {
  clamp,
  isClick,
  rectFrom,
  snap,
  square,
  windowAt,
  SNAP_TOLERANCE,
  type Point,
  type Rect,
} from "./selection";
import "./overlay.css";

const ACCENT = "#2e6bff";
const DIM = "rgba(0, 0, 0, 0.38)";
const LOUPE_SIZE = 128; // CSS pixels
const LOUPE_PIXELS = 17; // screen pixels across

type Phase = { kind: "idle" } | { kind: "dragging"; anchor: Point } | { kind: "done" };

export default function Overlay({ index }: { index: number }) {
  const [info, setInfo] = useState<OverlayInfo | null>(null);
  const image = useRef<HTMLImageElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const loupe = useRef<HTMLCanvasElement>(null);

  // Pointer state lives in refs: it changes on every mouse move, and a re-render per move
  // would be wasted work for a canvas that redraws itself anyway.
  const phase = useRef<Phase>({ kind: "idle" });
  const pointer = useRef<Point | null>(null);
  const selection = useRef<Rect | null>(null);
  const hovered = useRef(-1);
  const frame = useRef(0);

  useEffect(() => {
    ipc
      .overlayInfo(index)
      .then((value) => {
        setInfo(value);
        if (value.pointer) pointer.current = { x: value.pointer[0], y: value.pointer[1] };
      })
      .catch(() => ipc.cancelCapture());
  }, [index]);

  const windows = info?.windows.map((w) => w.rect) ?? [];
  const usesWindows = info?.mode === "area" || info?.mode === "window";

  function redraw() {
    cancelAnimationFrame(frame.current);
    frame.current = requestAnimationFrame(draw);
  }

  function draw() {
    const context = canvas.current?.getContext("2d");
    if (!info || !context) return;
    const s = info.scale;
    context.clearRect(0, 0, info.width, info.height);
    context.fillStyle = DIM;
    context.fillRect(0, 0, info.width, info.height);

    const window = hovered.current >= 0 ? windows[hovered.current] : null;
    const cut = selection.current ?? window;
    if (cut) {
      context.clearRect(cut.x, cut.y, cut.width, cut.height);
      context.strokeStyle = ACCENT;
      context.lineWidth = (selection.current ? 1.5 : 3) * s;
      context.strokeRect(cut.x, cut.y, cut.width, cut.height);
    }
    if (selection.current) drawSize(context, selection.current, s);
    drawLoupe();
  }

  function drawSize(context: CanvasRenderingContext2D, rect: Rect, s: number) {
    const label = `${Math.round(rect.width)} × ${Math.round(rect.height)}`;
    context.font = `${600} ${12 * s}px "Segoe UI Variable Text", "Segoe UI", sans-serif`;
    const width = context.measureText(label).width + 16 * s;
    const height = 22 * s;
    let x = rect.x + rect.width - width;
    let y = rect.y + rect.height + 8 * s;
    if (y + height > info!.height) y = rect.y + rect.height - height - 8 * s;
    x = Math.max(4 * s, x);
    context.fillStyle = "rgba(20, 20, 20, 0.82)";
    context.beginPath();
    context.roundRect(x, y, width, height, height / 2);
    context.fill();
    context.fillStyle = "#fff";
    context.textBaseline = "middle";
    context.fillText(label, x + 8 * s, y + height / 2 + 0.5 * s);
  }

  /** The magnifier beside the pointer: the pixels under it, large, for exact edges. */
  function drawLoupe() {
    const view = loupe.current;
    const picture = image.current;
    const at = pointer.current;
    if (!view || !picture || !info) return;
    const show = info.mode !== "window" && at !== null && phase.current.kind !== "done";
    view.style.display = show ? "block" : "none";
    if (!show || !at) return;

    const k = info.width / document.documentElement.clientWidth; // physical per CSS pixel
    const cssX = at.x / k;
    const cssY = at.y / k;
    const flipX = cssX + 24 + LOUPE_SIZE > document.documentElement.clientWidth;
    const flipY = cssY + 24 + LOUPE_SIZE + 22 > document.documentElement.clientHeight;
    view.style.left = `${flipX ? cssX - 24 - LOUPE_SIZE : cssX + 24}px`;
    view.style.top = `${flipY ? cssY - 24 - LOUPE_SIZE - 22 : cssY + 24}px`;

    const dpr = window.devicePixelRatio || 1;
    view.width = LOUPE_SIZE * dpr;
    view.height = (LOUPE_SIZE + 22) * dpr;
    const context = view.getContext("2d")!;
    context.scale(dpr, dpr);
    const half = Math.floor(LOUPE_PIXELS / 2);
    const cell = LOUPE_SIZE / LOUPE_PIXELS;
    context.imageSmoothingEnabled = false;
    context.fillStyle = "#000";
    context.fillRect(0, 0, LOUPE_SIZE, LOUPE_SIZE);
    context.drawImage(
      picture,
      Math.floor(at.x) - half,
      Math.floor(at.y) - half,
      LOUPE_PIXELS,
      LOUPE_PIXELS,
      0,
      0,
      LOUPE_SIZE,
      LOUPE_SIZE,
    );
    context.strokeStyle = "rgba(255,255,255,0.9)";
    context.lineWidth = 1;
    context.strokeRect(half * cell + 0.5, half * cell + 0.5, cell - 1, cell - 1);
    context.fillStyle = "rgba(20,20,20,0.85)";
    context.fillRect(0, LOUPE_SIZE, LOUPE_SIZE, 22);
    context.fillStyle = "#fff";
    context.font = '600 11px "Segoe UI", sans-serif';
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(`${Math.floor(at.x)}, ${Math.floor(at.y)}`, LOUPE_SIZE / 2, LOUPE_SIZE + 11);
  }

  function physical(event: { clientX: number; clientY: number }): Point {
    const k = info!.width / document.documentElement.clientWidth;
    return { x: event.clientX * k, y: event.clientY * k };
  }

  function finish(rect: Rect) {
    if (!info) return;
    const clamped = clamp(rect, info.width, info.height);
    if (!clamped) return;
    phase.current = { kind: "done" };
    ipc.finishCapture(index, clamped).catch(() => ipc.cancelCapture());
  }

  function onPointerDown(event: React.PointerEvent) {
    if (!info || phase.current.kind === "done") return;
    if (event.button === 2) {
      ipc.cancelCapture();
      return;
    }
    if (event.button !== 0) return;
    const p = physical(event);
    if (info.mode === "window") {
      const hit = windowAt(p, windows);
      if (hit >= 0) finish(windows[hit]);
      return;
    }
    (event.target as Element).setPointerCapture(event.pointerId);
    phase.current = { kind: "dragging", anchor: p };
    selection.current = null;
    hovered.current = usesWindows ? windowAt(p, windows) : -1;
    redraw();
  }

  function onPointerMove(event: React.PointerEvent) {
    if (!info || phase.current.kind === "done") return;
    const p = physical(event);
    pointer.current = p;
    const current = phase.current;
    if (current.kind === "dragging") {
      // Ctrl turns edge snapping off, as ⌘ does on the Mac; Shift makes a square.
      let q = event.ctrlKey ? p : snap(p, windows, SNAP_TOLERANCE * info.scale);
      if (event.shiftKey) q = square(current.anchor, q);
      selection.current = rectFrom(current.anchor, q);
      hovered.current = -1;
    } else if (usesWindows) {
      hovered.current = windowAt(p, windows);
    }
    redraw();
  }

  function onPointerUp(event: React.PointerEvent) {
    const current = phase.current;
    if (!info || current.kind !== "dragging") return;
    const p = physical(event);
    if (isClick(current.anchor, p, info.scale)) {
      // A click on a window takes the window.
      const hit = usesWindows ? windowAt(p, windows) : -1;
      if (hit >= 0) return finish(windows[hit]);
      phase.current = { kind: "idle" };
      selection.current = null;
    } else if (selection.current && clamp(selection.current, info.width, info.height)) {
      return finish(selection.current);
    } else {
      phase.current = { kind: "idle" };
      selection.current = null;
    }
    hovered.current = usesWindows ? windowAt(p, windows) : -1;
    redraw();
  }

  useEffect(() => {
    if (!info) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        ipc.cancelCapture();
      } else if (event.key === "Enter" && selection.current) {
        finish(selection.current);
      } else if (event.key.toLowerCase() === "a" && event.ctrlKey) {
        event.preventDefault();
        finish({ x: 0, y: 0, width: info.width, height: info.height });
      } else if (event.key === "Shift" || event.key === "Control") {
        redraw();
      }
    };
    // The display the pointer moves onto takes the keyboard, so Esc works wherever it is.
    const onEnter = () => getCurrentWindow().setFocus();
    window.addEventListener("keydown", onKey);
    document.addEventListener("pointerenter", onEnter);
    return () => {
      window.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerenter", onEnter);
    };
  }, [info]);

  function onLoaded() {
    if (!info) return;
    if (pointer.current && usesWindows) hovered.current = windowAt(pointer.current, windows);
    draw();
    ipc.overlayReady(index, info.pointer !== null);
  }

  if (!info) return null;
  return (
    <div
      className={`overlay ${info.mode === "window" ? "window-mode" : ""}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerLeave={() => {
        if (phase.current.kind === "idle") {
          pointer.current = null;
          hovered.current = -1;
          redraw();
        }
      }}
      onContextMenu={(event) => event.preventDefault()}
    >
      <img ref={image} src={info.imageUrl} onLoad={onLoaded} draggable={false} alt="" crossOrigin="anonymous" />
      <canvas ref={canvas} width={info.width} height={info.height} />
      <canvas ref={loupe} className="loupe" />
    </div>
  );
}
