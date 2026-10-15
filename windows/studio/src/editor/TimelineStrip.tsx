// The timeline — the Mac's `TimelineStrip`: a ruler, the clips (purple, trimmable at
// either edge), the zooms on their own lane (drag to move, edges to resize, double-click
// the lane for a new one), and the playhead.

import { useEffect, useRef, useState } from "react";
import { clockText } from "../lib/ipc";
import { clipDuration, duration as editLength, MIN_CLIP, trim } from "./model/clips";
import { newZoom, type Timeline } from "./model/timeline";
import type { Commit } from "./useEdit";

export type Selection = { kind: "zoom"; id: string } | { kind: "clip"; index: number } | null;

type Props = {
  timeline: Timeline;
  time: number;
  selection: Selection;
  onSelect: (s: Selection) => void;
  onSeek: (t: number) => void;
  commit: Commit;
};

const GUTTER = 14;

export default function TimelineStrip({ timeline, time, selection, onSelect, onSeek, commit }: Props) {
  const lane = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(800);
  const length = Math.max(0.1, editLength(timeline));

  useEffect(() => {
    const el = lane.current!;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth - GUTTER * 2));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const px = width / length;
  const x = (t: number) => GUTTER + t * px;
  const timeAt = (clientX: number) => {
    const r = lane.current!.getBoundingClientRect();
    return Math.min(length, Math.max(0, (clientX - r.left - GUTTER) / px));
  };

  /** Pointer drags in timeline seconds. */
  const dragging = (e: React.PointerEvent, onMove: (dt: number, key: string) => void, onClick?: () => void) => {
    e.stopPropagation();
    e.preventDefault();
    const el = e.currentTarget as HTMLElement;
    el.setPointerCapture(e.pointerId);
    const start = e.clientX;
    const key = `drag-${Math.random()}`;
    let moved = false;
    const move = (ev: PointerEvent) => {
      if (!moved && Math.abs(ev.clientX - start) < 3) return;
      moved = true;
      onMove((ev.clientX - start) / px, key);
    };
    const up = () => {
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      if (!moved) onClick?.();
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
  };

  const scrub = (e: React.PointerEvent) => {
    const el = e.currentTarget as HTMLElement;
    el.setPointerCapture(e.pointerId);
    onSeek(timeAt(e.clientX));
    const move = (ev: PointerEvent) => onSeek(timeAt(ev.clientX));
    const up = () => {
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
  };

  // Ruler marks at a step that leaves room for the labels.
  const steps = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
  const step = steps.find((s) => s * px >= 70) ?? 600;
  const marks: number[] = [];
  for (let t = 0; t <= length + 1e-6; t += step) marks.push(t);

  let elapsed = 0;
  const clips = timeline.clips.map((clip, index) => {
    const start = elapsed;
    elapsed += clipDuration(clip);
    return { clip, index, start, end: elapsed };
  });

  return (
    <div className="timeline" ref={lane}>
      <div className="ruler" onPointerDown={scrub}>
        {marks.map((t) => (
          <span key={t} className="mark" style={{ left: x(t) }}>
            {clockText(t)}
          </span>
        ))}
      </div>

      <div className="lane clips-lane" onPointerDown={scrub}>
        {clips.map(({ clip, index, start, end }) => {
          const selected = selection?.kind === "clip" && selection.index === index;
          return (
            <div
              key={clip.id}
              className={`clip ${selected ? "selected" : ""}`}
              style={{ left: x(start) + 1, width: Math.max(4, (end - start) * px - 2) }}
              onPointerDown={(e) => {
                dragging(e, () => {}, () => {
                  onSelect({ kind: "clip", index });
                  onSeek(timeAt(e.clientX));
                });
              }}
            >
              <span className="clip-label">
                {clip.speed !== 1 ? `${clip.speed}× · ` : ""}
                {clockText(end - start)}
              </span>
              <span className="clip-edge start" onPointerDown={(e) => dragging(e, (dt, key) => commit((t) => trimEdge(t, index, "start", dt, clip), key))} />
              <span className="clip-edge end" onPointerDown={(e) => dragging(e, (dt, key) => commit((t) => trimEdge(t, index, "end", dt, clip), key))} />
            </div>
          );
        })}
      </div>

      <div
        className="lane zooms-lane"
        onPointerDown={scrub}
        onDoubleClick={(e) => {
          const at = timeAt(e.clientX);
          const id = addZoomAt(commit, timeline, at);
          if (id) onSelect({ kind: "zoom", id });
        }}
      >
        {timeline.zooms.length === 0 && <span className="lane-hint">Double-click to add a zoom</span>}
        {timeline.zooms.map((z) => {
          const selected = selection?.kind === "zoom" && selection.id === z.id;
          const left = x(z.start);
          const w = Math.max(6, z.duration * px);
          const moveBy = (edge: "move" | "start" | "end") => (dt: number, key: string) =>
            commit((t) => {
              const zoom = t.zooms.find((q) => q.id === z.id);
              if (!zoom) return false;
              const total = editLength(t);
              if (edge === "move") zoom.start = Math.min(total - z.duration, Math.max(0, z.start + dt));
              else if (edge === "start") {
                const s = Math.min(z.start + z.duration - 0.3, Math.max(0, z.start + dt));
                zoom.duration = z.start + z.duration - s;
                zoom.start = s;
              } else zoom.duration = Math.min(total - z.start, Math.max(0.3, z.duration + dt));
              zoom.isEdited = true;
            }, key);
          return (
            <div
              key={z.id}
              className={`zoom ${selected ? "selected" : ""} ${z.isEnabled ? "" : "off"}`}
              style={{ left, width: w }}
              onPointerDown={(e) => dragging(e, moveBy("move"), () => onSelect({ kind: "zoom", id: z.id }))}
            >
              <span className="zoom-label">
                {z.scale.toFixed(1)}× {z.source === "click" ? "· Click" : ""}
              </span>
              <span className="clip-edge start" onPointerDown={(e) => dragging(e, moveBy("start"))} />
              <span className="clip-edge end" onPointerDown={(e) => dragging(e, moveBy("end"))} />
            </div>
          );
        })}
      </div>

      <div className="playhead" style={{ left: x(Math.min(time, length)) }} onPointerDown={scrub}>
        <span className="playhead-knob" />
      </div>
    </div>
  );
}

/** Trims from where the drag began, so the drag is absolute rather than accumulating. */
function trimEdge(t: Timeline, index: number, edge: "start" | "end", dt: number, original: { sourceStart: number; sourceDuration: number }) {
  const clip = t.clips[index];
  if (!clip) return false;
  clip.sourceStart = original.sourceStart;
  clip.sourceDuration = original.sourceDuration;
  trim(t, index, edge, dt);
  return clip.sourceDuration / clip.speed >= MIN_CLIP;
}

/** A new zoom at `at`, three seconds long or as much as fits before the next. */
export function addZoomAt(commit: Commit, timeline: Timeline, at: number): string | null {
  const total = editLength(timeline);
  const inside = timeline.zooms.some((z) => at >= z.start && at < z.start + z.duration);
  if (inside || total < 0.5) return null;
  const next = timeline.zooms.filter((z) => z.start > at).reduce((m, z) => Math.min(m, z.start), total);
  const length = Math.min(3, next - at);
  if (length < 0.5) return null;
  const zoom = newZoom(at, length, { source: "manual" });
  commit((t) => {
    t.zooms.push(zoom);
    t.zooms.sort((a, b) => a.start - b.start);
  });
  return zoom.id;
}
