// The picture — the Mac's `PreviewPane`: the edit drawn by the same `Scene` the export
// uses, in a dark well. Plays the recording along the edit (each clip's stretch at its
// speed), with its sound. With a zoom selected and paused it shows the whole picture
// and the zoom's square to drag; with Crop chosen, the whole recording and the crop.

import { useEffect, useImperativeHandle, useRef, useState, type Ref } from "react";
import { cameraCenter, MAX_SCALE, zoomArea } from "./model/camera";
import { clipAt, clipDuration, sourceTime } from "./model/clips";
import type { Timeline } from "./model/timeline";
import type { Commit } from "./useEdit";
import type { Scene } from "./render/scene";

export type PreviewHandle = { play: () => void; pause: () => void };

type Props = {
  scene: Scene;
  timeline: Timeline;
  time: number;
  playing: boolean;
  videoUrl: string;
  sounds: { url: string; gain: number }[];
  editing: { kind: "zoom"; id: string } | { kind: "crop" } | null;
  commit: Commit;
  onTime: (t: number) => void;
  onPlaying: (playing: boolean) => void;
  handle: Ref<PreviewHandle>;
};

type Box = { x: number; y: number; width: number; height: number };

export default function Preview(props: Props) {
  const { scene, timeline, time, editing, commit } = props;
  const well = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const audios = useRef<HTMLAudioElement[]>([]);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const playing = useRef(false);
  const clipIndex = useRef(0);
  const live = useRef({ timeline, time, editing });
  live.current = { timeline, time, editing };

  // While framing a zoom or the crop, the picture is shown whole.
  const restTimeline = (t: Timeline): Timeline => {
    const e = live.current.editing;
    if (!e || playing.current) return t;
    if (e.kind === "zoom") return { ...t, zooms: [], camera: { ...t.camera, wholeVideoZoom: 1 } };
    return { ...t, zooms: [], camera: { ...t.camera, wholeVideoZoom: 1 }, style: { ...t.style, crop: null } };
  };

  const output = scene.outputSize(editing?.kind === "crop" ? { ...timeline.style, crop: null } : timeline.style);

  // Fit the output into the well.
  useEffect(() => {
    const el = well.current!;
    const fit = () => {
      const pad = 24;
      const w = el.clientWidth - pad * 2;
      const h = el.clientHeight - pad * 2;
      const k = Math.min(w / output.width, h / output.height);
      setSize({ width: Math.max(1, Math.floor(output.width * k)), height: Math.max(1, Math.floor(output.height * k)) });
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, [output.width, output.height]);

  const draw = (t: Timeline, at: number) => {
    const c = canvas.current;
    const v = video.current;
    if (!c || !size.width) return;
    const ctx = c.getContext("2d")!;
    const dpr = window.devicePixelRatio || 1;
    const shown = restTimeline(t);
    const out = scene.outputSize(shown.style);
    const hasFrame = v && v.readyState >= 2;
    ctx.clearRect(0, 0, c.width, c.height);
    scene.draw(ctx, shown, at, hasFrame ? v : null, (size.width * dpr) / out.width);
  };

  // Paused: seek to the moment and draw it.
  useEffect(() => {
    if (playing.current) return;
    const v = video.current;
    if (!v) return;
    const s = sourceTime(timeline, time);
    if (Math.abs(v.currentTime - s) > 0.001) {
      v.currentTime = s;
      const once = () => draw(live.current.timeline, live.current.time);
      v.addEventListener("seeked", once, { once: true });
    }
    draw(timeline, time);
  });

  // Playing: the video is the clock.
  useEffect(() => {
    let frame = 0;
    const tick = () => {
      frame = requestAnimationFrame(tick);
      const v = video.current;
      if (!playing.current || !v) return;
      const t = live.current.timeline;
      const clip = t.clips[clipIndex.current];
      if (!clip) return stop();
      let start = 0;
      for (let i = 0; i < clipIndex.current; i++) start += clipDuration(t.clips[i]);
      const end = clip.sourceStart + clip.sourceDuration;
      if (v.currentTime >= end - 1 / 240 || v.ended) {
        // On to the next clip, or the end.
        if (clipIndex.current + 1 >= t.clips.length) {
          props.onTime(start + clipDuration(clip));
          return stop();
        }
        clipIndex.current++;
        const next = t.clips[clipIndex.current];
        v.currentTime = next.sourceStart;
        v.playbackRate = next.speed;
        syncSound(next.sourceStart, next.speed, true);
        return;
      }
      const now = start + Math.max(0, v.currentTime - clip.sourceStart) / clip.speed;
      syncSound(v.currentTime, clip.speed, false);
      draw(t, now);
      props.onTime(now);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [size.width]);

  const syncSound = (s: number, rate: number, hard: boolean) => {
    for (const a of audios.current) {
      if (!a) continue;
      if (a.playbackRate !== rate) a.playbackRate = rate;
      if (hard || Math.abs(a.currentTime - s) > 0.12) a.currentTime = s;
      if (a.paused && playing.current) a.play().catch(() => {});
    }
  };

  const play = () => {
    const v = video.current;
    if (!v) return;
    const t = live.current.timeline;
    let at = live.current.time;
    const total = t.clips.reduce((n, c) => n + clipDuration(c), 0);
    if (at >= total - 0.05) at = 0;
    const found = clipAt(t, at);
    if (!found) return;
    clipIndex.current = found.index;
    v.currentTime = sourceTime(t, at);
    v.playbackRate = found.clip.speed;
    playing.current = true;
    v.play().catch(() => stop());
    syncSound(v.currentTime, found.clip.speed, true);
    props.onPlaying(true);
  };

  const stop = () => {
    playing.current = false;
    video.current?.pause();
    for (const a of audios.current) a?.pause();
    props.onPlaying(false);
  };

  useImperativeHandle(props.handle, () => ({ play, pause: stop }));

  // MARK: Framing a zoom or the crop on the picture

  const rest = scene.videoFrame(editing?.kind === "crop" ? { ...timeline.style, crop: null } : timeline.style, output);
  const k = size.width / output.width;
  const restBox: Box = { x: rest.x * k, y: rest.y * k, width: rest.width * k, height: rest.height * k };
  const zoom = editing?.kind === "zoom" ? timeline.zooms.find((z) => z.id === editing.id) : undefined;
  let box: Box | null = null;
  if (zoom && !props.playing) {
    const a = zoomArea(zoom);
    box = { x: restBox.x + a.x * restBox.width, y: restBox.y + a.y * restBox.height, width: a.side * restBox.width, height: a.side * restBox.height };
  } else if (editing?.kind === "crop" && !props.playing) {
    const c = timeline.style.crop ?? { x: 0, y: 0, width: 1, height: 1 };
    box = { x: restBox.x + c.x * restBox.width, y: restBox.y + c.y * restBox.height, width: c.width * restBox.width, height: c.height * restBox.height };
  }

  const drag = (e: React.PointerEvent, handle: "move" | "nw" | "ne" | "sw" | "se") => {
    e.preventDefault();
    e.stopPropagation();
    const startX = e.clientX;
    const startY = e.clientY;
    const target = e.currentTarget as HTMLElement;
    target.setPointerCapture(e.pointerId);
    const z0 = zoom ? { ...zoom } : null;
    const c0 = timeline.style.crop ?? { x: 0, y: 0, width: 1, height: 1 };
    const key = `frame-${Math.random()}`;
    const move = (ev: PointerEvent) => {
      const dx = (ev.clientX - startX) / restBox.width;
      const dy = (ev.clientY - startY) / restBox.height;
      if (z0) {
        commit((t) => {
          const z = t.zooms.find((x) => x.id === z0.id);
          if (!z) return false;
          const a = zoomArea(z0);
          if (handle === "move") {
            z.center = cameraCenter([a.x + a.side / 2 + dx, a.y + a.side / 2 + dy], z.scale);
          } else {
            // A square, from the opposite corner.
            const grow = handle === "se" ? Math.max(dx, dy) : handle === "nw" ? Math.max(-dx, -dy) : handle === "ne" ? Math.max(dx, -dy) : Math.max(-dx, dy);
            const side = Math.min(1, Math.max(1 / MAX_SCALE, a.side + grow));
            const ax = handle.includes("w") ? a.x + a.side - side : a.x;
            const ay = handle.includes("n") ? a.y + a.side - side : a.y;
            z.scale = Math.min(MAX_SCALE, Math.max(1, 1 / side));
            z.center = cameraCenter([ax + side / 2, ay + side / 2], z.scale);
          }
          z.followsCursor = false;
          z.isEdited = true;
        }, key);
      } else {
        commit((t) => {
          let { x, y, width, height } = c0;
          const min = 0.05;
          if (handle === "move") {
            x = Math.min(1 - width, Math.max(0, x + dx));
            y = Math.min(1 - height, Math.max(0, y + dy));
          } else {
            if (handle.includes("w")) {
              const nx = Math.min(x + width - min, Math.max(0, x + dx));
              width += x - nx;
              x = nx;
            }
            if (handle.includes("e")) width = Math.min(1 - x, Math.max(min, width + dx));
            if (handle.includes("n")) {
              const ny = Math.min(y + height - min, Math.max(0, y + dy));
              height += y - ny;
              y = ny;
            }
            if (handle.includes("s")) height = Math.min(1 - y, Math.max(min, height + dy));
          }
          const whole = x <= 0.001 && y <= 0.001 && width >= 0.999 && height >= 0.999;
          t.style.crop = whole ? null : { x, y, width, height };
        }, key);
      }
    };
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
  };

  const dpr = window.devicePixelRatio || 1;
  return (
    <div className="preview-well" ref={well}>
      <div className="preview-stage" style={{ width: size.width, height: size.height }}>
        <video ref={video} className="source-video" src={props.videoUrl} muted preload="auto" playsInline onLoadedData={() => draw(live.current.timeline, live.current.time)} onSeeked={() => draw(live.current.timeline, live.current.time)} />
        <canvas ref={canvas} width={Math.round(size.width * dpr)} height={Math.round(size.height * dpr)} style={{ width: size.width, height: size.height }} />
        {box && (
          <>
            <div className="frame-shade" style={{ clipPath: shade(restBox, box) }} />
            <div className={`frame-box ${editing?.kind}`} style={{ left: box.x, top: box.y, width: box.width, height: box.height }} onPointerDown={(e) => drag(e, "move")}>
              {(["nw", "ne", "sw", "se"] as const).map((h) => (
                <span key={h} className={`frame-handle ${h}`} onPointerDown={(e) => drag(e, h)} />
              ))}
              {zoom && <span className="frame-label">{zoom.scale.toFixed(1)}×</span>}
            </div>
          </>
        )}
      </div>
      {props.sounds.map((s, i) => (
        <audio
          key={s.url}
          src={s.url}
          preload="auto"
          ref={(el) => {
            audios.current[i] = el!;
            if (el) {
              el.volume = Math.min(1, s.gain);
              el.preservesPitch = true;
            }
          }}
        />
      ))}
    </div>
  );
}

/** Everything in the picture but the box, darkened. */
function shade(outer: Box, inner: Box): string {
  const o = (x: number, y: number) => `${x}px ${y}px`;
  return `polygon(evenodd, ${o(outer.x, outer.y)}, ${o(outer.x + outer.width, outer.y)}, ${o(outer.x + outer.width, outer.y + outer.height)}, ${o(outer.x, outer.y + outer.height)}, ${o(outer.x, outer.y)}, ${o(inner.x, inner.y)}, ${o(inner.x, inner.y + inner.height)}, ${o(inner.x + inner.width, inner.y + inner.height)}, ${o(inner.x + inner.width, inner.y)}, ${o(inner.x, inner.y)})`;
}
