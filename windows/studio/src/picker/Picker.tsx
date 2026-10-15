// Choosing what to record, over each display — the Mac's target overlay:
// - Display: the display under the pointer lights up; a click records it.
// - Window: the window under the pointer is outlined; a click records it.
// - Area: drag out a rectangle; Enter or the Record button records it.
// Esc, or a right click, calls it off.

import { emit } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useMemo, useRef, useState } from "react";
import { Icon } from "../../../src/ui/icon";
import { studio, type DisplayInfo, type WindowInfo } from "../lib/ipc";
import "./picker.css";

type Mode = "display" | "window" | "area";
type Rect = { x: number; y: number; width: number; height: number };

export default function Picker({ mode }: { mode: Mode }) {
  const [display, setDisplay] = useState<DisplayInfo | null>(null);
  const [windows, setWindows] = useState<WindowInfo[]>([]);
  const [pointer, setPointer] = useState<{ x: number; y: number } | null>(null);
  const [area, setArea] = useState<Rect | null>(null);
  const [inside, setInside] = useState(false);
  const anchor = useRef<{ x: number; y: number } | null>(null);
  const dpr = window.devicePixelRatio || 1;

  useEffect(() => {
    const me = getCurrentWindow();
    Promise.all([me.outerPosition(), studio.displays(), mode === "window" ? studio.windows() : Promise.resolve([])]).then(([position, displays, list]) => {
      // This overlay's display: the one it was laid over.
      const mine = displays.find((d) => d.x === position.x && d.y === position.y) ?? displays[0] ?? null;
      setDisplay(mine);
      setWindows(list);
      me.show();
      me.setFocus();
    });
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") emit("picker:cancelled");
      if (e.key === "Enter") confirmArea();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  /** A desktop pixel, from a point in this overlay. */
  const desktop = (e: { clientX: number; clientY: number }) => ({ x: (display?.x ?? 0) + e.clientX * dpr, y: (display?.y ?? 0) + e.clientY * dpr });

  // The topmost window under the pointer (the list is front to back).
  const hovered = useMemo(() => {
    if (mode !== "window" || !pointer) return null;
    return windows.find((w) => pointer.x >= w.x && pointer.x < w.x + w.width && pointer.y >= w.y && pointer.y < w.y + w.height) ?? null;
  }, [pointer, windows, mode]);

  const toLocal = (r: Rect): Rect => ({ x: (r.x - (display?.x ?? 0)) / dpr, y: (r.y - (display?.y ?? 0)) / dpr, width: r.width / dpr, height: r.height / dpr });

  function choose() {
    if (!display) return;
    if (mode === "display") {
      emit("picker:chosen", { target: { kind: "display", index: display.index }, label: display.name });
    } else if (mode === "window" && hovered) {
      emit("picker:chosen", { target: { kind: "window", hwnd: hovered.hwnd }, label: hovered.title });
    }
  }

  function confirmArea() {
    if (mode !== "area" || !area || !display || area.width < 16 || area.height < 16) return;
    // In pixels of the display, from its top left.
    const rect: [number, number, number, number] = [area.x * dpr, area.y * dpr, area.width * dpr, area.height * dpr].map(Math.round) as [number, number, number, number];
    emit("picker:chosen", { target: { kind: "display", index: display.index }, area: rect, label: `${rect[2]} × ${rect[3]} area` });
  }

  const outline = mode === "window" && hovered ? toLocal(hovered) : null;

  return (
    <div
      className={`picker ${mode} ${inside ? "inside" : ""}`}
      onMouseEnter={() => setInside(true)}
      onMouseLeave={() => {
        setInside(false);
        setPointer(null);
      }}
      onMouseMove={(e) => {
        setPointer(desktop(e));
        const a = anchor.current;
        if (mode === "area" && a) {
          setArea({ x: Math.min(a.x, e.clientX), y: Math.min(a.y, e.clientY), width: Math.abs(e.clientX - a.x), height: Math.abs(e.clientY - a.y) });
        }
      }}
      onMouseDown={(e) => {
        if (e.button === 2) return emit("picker:cancelled");
        if (mode === "area" && !(e.target as HTMLElement).closest(".area-actions")) {
          anchor.current = { x: e.clientX, y: e.clientY };
          setArea({ x: e.clientX, y: e.clientY, width: 0, height: 0 });
        }
      }}
      onMouseUp={() => {
        anchor.current = null;
      }}
      onClick={(e) => {
        if (mode !== "area" && !(e.target as HTMLElement).closest(".hint")) choose();
      }}
      onContextMenu={(e) => e.preventDefault()}
    >
      {mode === "display" && display && (
        <div className="display-card">
          <Icon name="display" size={34} weight={1.4} />
          <div className="card-title">{display.name}</div>
          <div className="card-sub">
            {display.width} × {display.height}
          </div>
          <div className="card-action">Click to record this display</div>
        </div>
      )}

      {outline && (
        <div className="window-outline" style={{ left: outline.x, top: outline.y, width: outline.width, height: outline.height }}>
          <span className="window-label">
            {hovered!.title} <em>{hovered!.app}</em>
          </span>
        </div>
      )}

      {mode === "area" && area && area.width > 0 && (
        <>
          <div className="area" style={{ left: area.x, top: area.y, width: area.width, height: area.height }}>
            <span className="area-size">
              {Math.round(area.width * dpr)} × {Math.round(area.height * dpr)}
            </span>
          </div>
          {!anchor.current && area.width >= 16 && area.height >= 16 && (
            <div className="area-actions" style={{ left: area.x + area.width / 2, top: Math.min(area.y + area.height + 12, window.innerHeight - 52) }}>
              <button className="area-button" onClick={() => setArea(null)}>
                Cancel
              </button>
              <button className="area-button record" onClick={confirmArea}>
                <span className="dot" /> Record
              </button>
            </div>
          )}
        </>
      )}

      {inside && (mode !== "area" || !area) && (
        <div className="hint">
          {mode === "window" ? "Click a window to record it" : mode === "area" ? "Drag out the area to record" : ""}
          {mode !== "display" && <span className="keys">Esc to cancel</span>}
        </div>
      )}
    </div>
  );
}
