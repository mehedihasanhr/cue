// The settings column — the Mac's `InspectorPanel`: Export at its head, then the panel
// for the chosen tool, or for what is selected on the timeline.

import { memo, type ReactNode } from "react";
import { Icon, type IconName } from "../../../src/ui/icon";
import { Segmented, Select, Switch } from "../../../src/settings/controls";
import { clipDuration, setSpeed } from "./model/clips";
import { ZOOM_SPEEDS, type Aspect, type Background, type ClickStyle, type RGBA, type Timeline } from "./model/timeline";
import { PRESETS, swatch } from "./render/backgrounds";
import type { Selection } from "./TimelineStrip";
import type { Commit } from "./useEdit";

export type Tool = "frame" | "crop" | "camera" | "cursor" | "audio";
export const TOOLS: { id: Tool; title: string; symbol: IconName }[] = [
  { id: "frame", title: "Frame", symbol: "photo" },
  { id: "crop", title: "Crop", symbol: "crop" },
  { id: "camera", title: "Zoom", symbol: "zoom.area" },
  { id: "cursor", title: "Pointer", symbol: "cursorarrow.rays" },
  { id: "audio", title: "Audio", symbol: "waveform" },
];

type Props = {
  timeline: Timeline;
  tool: Tool;
  selection: Selection;
  commit: Commit;
  onExport: () => void;
  onAutoZoom: () => void;
  onDeleteSelection: () => void;
  hasClicks: boolean;
};

export default memo(function Inspector(props: Props) {
  const { timeline: t, selection } = props;
  const zoom = selection?.kind === "zoom" ? t.zooms.find((z) => z.id === selection.id) : undefined;
  const clip = selection?.kind === "clip" ? t.clips[selection.index] : undefined;
  return (
    <aside className="inspector">
      <div className="inspector-head">
        <span className="inspector-title">{zoom ? "Zoom" : clip ? "Clip" : TOOLS.find((x) => x.id === props.tool)?.title}</span>
        <button className="export-button" onClick={props.onExport}>
          Export
        </button>
      </div>
      <div className="inspector-body">
        {zoom ? (
          <ZoomPanel {...props} id={zoom.id} />
        ) : clip && selection?.kind === "clip" ? (
          <ClipPanel {...props} index={selection.index} />
        ) : props.tool === "frame" ? (
          <FramePanel {...props} />
        ) : props.tool === "crop" ? (
          <CropPanel {...props} />
        ) : props.tool === "camera" ? (
          <CameraPanel {...props} />
        ) : props.tool === "cursor" ? (
          <CursorPanel {...props} />
        ) : (
          <AudioPanel {...props} />
        )}
      </div>
    </aside>
  );
});

// MARK: - Controls

function Section({ title, children, trailing }: { title: string; children: ReactNode; trailing?: ReactNode }) {
  return (
    <section className="i-section">
      <header>
        <h3>{title}</h3>
        {trailing}
      </header>
      {children}
    </section>
  );
}

function SliderRow({ label, value, min, max, step, format, onChange, disabled }: { label: string; value: number; min: number; max: number; step: number; format: (v: number) => string; onChange: (v: number) => void; disabled?: boolean }) {
  return (
    <label className={`i-slider ${disabled ? "disabled" : ""}`}>
      <span className="i-slider-top">
        <span>{label}</span>
        <span className="i-value">{format(value)}</span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        disabled={disabled}
        style={{ ["--fill" as string]: `${((value - min) / (max - min)) * 100}%` }}
        onChange={(e) => onChange(Number(e.target.value))}
      />
    </label>
  );
}

function ToggleRow({ label, checked, onChange, note }: { label: string; checked: boolean; onChange: (v: boolean) => void; note?: string }) {
  return (
    <div className="i-toggle">
      <span>
        {label}
        {note && <small>{note}</small>}
      </span>
      <Switch small checked={checked} onChange={onChange} label={label} />
    </div>
  );
}

const pct = (v: number) => `${Math.round(v * 100)}%`;
const times = (v: number) => `${v.toFixed(v < 10 ? 1 : 0)}×`;
const secs = (v: number) => `${v.toFixed(1)} s`;

const hex = (c: RGBA) => "#" + [c.r, c.g, c.b].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
const rgba = (h: string): RGBA => ({ r: parseInt(h.slice(1, 3), 16) / 255, g: parseInt(h.slice(3, 5), 16) / 255, b: parseInt(h.slice(5, 7), 16) / 255, a: 1 });

function ColorWell({ value, onChange, label }: { value: RGBA; onChange: (c: RGBA) => void; label: string }) {
  return (
    <label className="i-color" aria-label={label}>
      <input type="color" value={hex(value)} onChange={(e) => onChange(rgba(e.target.value))} />
      <span style={{ background: hex(value) }} />
    </label>
  );
}

// MARK: - Panels

function FramePanel({ timeline: t, commit }: Props) {
  const s = t.style;
  const set = (key: string, change: (t: Timeline) => void) => commit(change, key);
  const backgrounds: { id: string; b: Background }[] = [
    { id: "indigo", b: { kind: "gradient", from: { r: 0.36, g: 0.42, b: 0.85, a: 1 }, to: { r: 0.15, g: 0.16, b: 0.35, a: 1 }, angle: 0.25 } },
    ...Object.keys(PRESETS).map((name) => ({ id: name, b: { kind: "wallpaper", id: `cue:${name}` } as Background })),
  ];
  const current = JSON.stringify(s.background);
  const solid = s.background.kind === "color" ? s.background.color : { r: 1, g: 1, b: 1, a: 1 };
  return (
    <>
      <Section title="Background">
        <div className="wallpapers">
          {backgrounds.map(({ id, b }) => (
            <button key={id} title={id[0].toUpperCase() + id.slice(1)} className={`wallpaper ${JSON.stringify(b) === current ? "on" : ""}`} style={{ background: swatch(b) }} onClick={() => commit((t) => void (t.style.background = b))} />
          ))}
        </div>
        <div className="i-row">
          <span>Colour</span>
          <span className="i-row-end">
            <button className={`chip ${s.background.kind === "transparent" ? "on" : ""}`} onClick={() => commit((t) => void (t.style.background = { kind: "transparent" }))}>
              None
            </button>
            <ColorWell label="Background colour" value={solid} onChange={(c) => set("bg-color", (t) => void (t.style.background = { kind: "color", color: c }))} />
          </span>
        </div>
        <SliderRow label="Blur" value={s.backgroundBlur} min={0} max={0.1} step={0.005} format={pct} disabled={s.background.kind !== "image"} onChange={(v) => set("blur", (t) => void (t.style.backgroundBlur = v))} />
      </Section>
      <Section title="Shape">
        <Select<Aspect>
          label="Aspect ratio"
          value={s.aspect}
          onChange={(v) => commit((t) => void (t.style.aspect = v))}
          options={[
            { value: "source", title: "As recorded" },
            { value: "wide16x9", title: "Wide 16:9" },
            { value: "wide16x10", title: "Wide 16:10" },
            { value: "classic4x3", title: "Classic 4:3" },
            { value: "square", title: "Square 1:1" },
            { value: "portrait4x5", title: "Portrait 4:5" },
            { value: "portrait3x4", title: "Portrait 3:4" },
            { value: "vertical9x16", title: "Vertical 9:16" },
          ]}
        />
        <SliderRow label="Padding" value={s.padding} min={0} max={0.3} step={0.005} format={pct} onChange={(v) => set("padding", (t) => void (t.style.padding = v))} />
        <SliderRow label="Corners" value={s.cornerRadius} min={0} max={0.1} step={0.002} format={pct} onChange={(v) => set("corners", (t) => void (t.style.cornerRadius = v))} />
      </Section>
      <Section title="Shadow">
        <SliderRow label="Size" value={s.shadowRadius} min={0} max={0.1} step={0.002} format={pct} onChange={(v) => set("shadow", (t) => void (t.style.shadowRadius = v))} />
        <SliderRow label="Strength" value={s.shadowOpacity} min={0} max={1} step={0.01} format={pct} onChange={(v) => set("shadow-o", (t) => void (t.style.shadowOpacity = v))} />
      </Section>
      <Section title="Border" trailing={<ColorWell label="Border colour" value={s.borderColor} onChange={(c) => set("border-c", (t) => void (t.style.borderColor = c))} />}>
        <SliderRow label="Width" value={s.borderWidth} min={0} max={0.03} step={0.001} format={pct} onChange={(v) => set("border", (t) => void (t.style.borderWidth = v))} />
      </Section>
    </>
  );
}

function CropPanel({ timeline: t, commit }: Props) {
  const c = t.style.crop;
  return (
    <Section title="Crop" trailing={c ? <button className="link" onClick={() => commit((t) => void (t.style.crop = null))}>Reset</button> : undefined}>
      <p className="i-note">Drag the frame on the picture to crop the recording. The corners resize it.</p>
      {c && (
        <p className="i-note mono">
          {pct(c.x)}, {pct(c.y)} · {pct(c.width)} × {pct(c.height)}
        </p>
      )}
    </Section>
  );
}

function CameraPanel({ timeline: t, commit, onAutoZoom, hasClicks }: Props) {
  const m = t.camera;
  const set = (key: string, change: (t: Timeline) => void) => commit(change, key);
  return (
    <>
      <Section title="Zooms">
        <button className="wide-button" disabled={!hasClicks} onClick={onAutoZoom}>
          <Icon name="wand.and.stars" size={14} /> Zoom in on clicks
        </button>
        <p className="i-note">{hasClicks ? "Replaces the zooms made for clicks; ones you placed stay." : "This recording has no clicks to zoom in on."}</p>
        <div className="i-row">
          <span>Speed</span>
          <Segmented label="Zoom speed" value={m.zoomSpeed} options={[{ value: "slow", title: "Slow" }, { value: "medium", title: "Medium" }, { value: "fast", title: "Fast" }]} onChange={(v) => commit((t) => {
            t.camera.zoomSpeed = v;
            for (const z of t.zooms) if (!z.isEdited) z.transition = ZOOM_SPEEDS[v];
          })} />
        </div>
        <ToggleRow label="Glide between zooms" checked={m.glidesBetweenZooms} onChange={(v) => commit((t) => void (t.camera.glidesBetweenZooms = v))} />
        <ToggleRow label="Zoom the whole frame" note="Corners and shadow grow with the picture" checked={m.zoomsWholeFrame} onChange={(v) => commit((t) => void (t.camera.zoomsWholeFrame = v))} />
      </Section>
      <Section title="Following the pointer">
        <SliderRow label="Follow" value={m.follow} min={0} max={1} step={0.05} format={pct} onChange={(v) => set("follow", (t) => void (t.camera.follow = v))} />
        <SliderRow label="Steadiness" value={m.steadiness} min={0} max={2} step={0.05} format={secs} onChange={(v) => set("steady", (t) => void (t.camera.steadiness = v))} />
        <SliderRow label="Safe area" value={m.safeArea} min={0.3} max={1} step={0.01} format={pct} onChange={(v) => set("safe", (t) => void (t.camera.safeArea = v))} />
      </Section>
      <Section title="Whole video">
        <SliderRow label="Zoom" value={m.wholeVideoZoom} min={1} max={3} step={0.05} format={times} onChange={(v) => set("whole", (t) => void (t.camera.wholeVideoZoom = v))} />
      </Section>
    </>
  );
}

function ZoomPanel({ timeline: t, commit, id, onDeleteSelection }: Props & { id: string }) {
  const z = t.zooms.find((q) => q.id === id)!;
  const set = (key: string, change: (z: Timeline["zooms"][number]) => void) =>
    commit((t) => {
      const zoom = t.zooms.find((q) => q.id === id);
      if (!zoom) return false;
      change(zoom);
      zoom.isEdited = true;
    }, key);
  return (
    <>
      <Section title="Zoom">
        <SliderRow label="Depth" value={z.scale} min={1} max={5} step={0.05} format={times} onChange={(v) => set(`scale-${id}`, (z) => void (z.scale = v))} />
        <ToggleRow label="Follow the pointer" checked={z.followsCursor} onChange={(v) => set(`follow-${id}`, (z) => void (z.followsCursor = v))} />
        <p className="i-note">Drag the square on the picture to aim it.</p>
      </Section>
      <Section title="Motion">
        <div className="i-row">
          <span>Curve</span>
          <Segmented label="Easing" value={z.easing} options={[{ value: "spring", title: "Smooth" }, { value: "easeInOut", title: "Ease" }, { value: "linear", title: "Linear" }]} onChange={(v) => set("ease", (z) => void (z.easing = v))} />
        </div>
        <SliderRow label="Transition" value={z.transition} min={0.1} max={2} step={0.05} format={secs} disabled={z.isInstant} onChange={(v) => set(`tr-${id}`, (z) => void (z.transition = v))} />
        <ToggleRow label="Cut in and out" checked={z.isInstant} onChange={(v) => set("instant", (z) => void (z.isInstant = v))} />
        <ToggleRow label="On" checked={z.isEnabled} onChange={(v) => set("enabled", (z) => void (z.isEnabled = v))} />
      </Section>
      <button className="wide-button danger" onClick={onDeleteSelection}>
        <Icon name="trash" size={14} /> Delete Zoom
      </button>
    </>
  );
}

function ClipPanel({ timeline: t, commit, index, onDeleteSelection }: Props & { index: number }) {
  const c = t.clips[index];
  const speeds = [0.5, 1, 1.5, 2, 4];
  return (
    <>
      <Section title="Speed">
        <div className="chips">
          {speeds.map((s) => (
            <button key={s} className={`chip ${c.speed === s ? "on" : ""}`} onClick={() => commit((t) => setSpeed(t, index, s))}>
              {s}×
            </button>
          ))}
        </div>
        <SliderRow label="Speed" value={c.speed} min={0.25} max={8} step={0.25} format={times} onChange={(v) => commit((t) => setSpeed(t, index, v), `speed-${c.id}`)} />
        <p className="i-note">Plays for {clipDuration(c).toFixed(1)} s.</p>
      </Section>
      <button className="wide-button danger" disabled={t.clips.length < 2} onClick={onDeleteSelection}>
        <Icon name="trash" size={14} /> Delete Clip
      </button>
    </>
  );
}

function CursorPanel({ timeline: t, commit }: Props) {
  const c = t.cursor;
  const set = (key: string, change: (t: Timeline) => void) => commit(change, key);
  return (
    <>
      <Section title="Pointer" trailing={<Switch small checked={c.isVisible} onChange={(v) => commit((t) => void (t.cursor.isVisible = v))} label="Show the pointer" />}>
        <SliderRow label="Size" value={c.scale} min={0.5} max={4} step={0.05} format={times} disabled={!c.isVisible} onChange={(v) => set("size", (t) => void (t.cursor.scale = v))} />
        <SliderRow label="Smoothing" value={c.smoothing} min={0} max={1} step={0.05} format={pct} disabled={!c.isVisible} onChange={(v) => set("smooth", (t) => void (t.cursor.smoothing = v))} />
        <ToggleRow label="Always an arrow" checked={c.alwaysArrow} onChange={(v) => commit((t) => void (t.cursor.alwaysArrow = v))} />
        <ToggleRow label="Hide when still" checked={c.hidesWhenIdle} onChange={(v) => commit((t) => void (t.cursor.hidesWhenIdle = v))} />
        {c.hidesWhenIdle && <SliderRow label="After" value={c.idleDelay} min={0.5} max={10} step={0.5} format={secs} onChange={(v) => set("idle", (t) => void (t.cursor.idleDelay = v))} />}
        <ToggleRow label="Size stays as zooms go in" checked={c.sizeIsIndependentOfZoom} onChange={(v) => commit((t) => void (t.cursor.sizeIsIndependentOfZoom = v))} />
      </Section>
      <Section title="Clicks" trailing={<Switch small checked={c.clickHighlight} onChange={(v) => commit((t) => void (t.cursor.clickHighlight = v))} label="Show clicks" />}>
        <div className="i-row">
          <span>Style</span>
          <Segmented<ClickStyle> label="Click style" value={c.clickStyle} options={[{ value: "ring", title: "Ring" }, { value: "ripple", title: "Ripple" }, { value: "glow", title: "Glow" }]} onChange={(v) => commit((t) => void (t.cursor.clickStyle = v))} />
        </div>
        <div className="i-row">
          <span>Colour</span>
          <ColorWell label="Click colour" value={c.clickColor} onChange={(v) => set("click-c", (t) => void (t.cursor.clickColor = v))} />
        </div>
        <SliderRow label="Size" value={c.clickSize} min={0.02} max={0.2} step={0.005} format={pct} onChange={(v) => set("click-s", (t) => void (t.cursor.clickSize = v))} />
        <ToggleRow label="Press the pointer" checked={c.clickEffect} onChange={(v) => commit((t) => void (t.cursor.clickEffect = v))} />
      </Section>
    </>
  );
}

function AudioPanel({ timeline: t, commit }: Props) {
  return (
    <>
      <Section title="Sound" trailing={<Switch small checked={!t.sound.isMuted} onChange={(v) => commit((t) => void (t.sound.isMuted = !v))} label="Sound on" />}>
        <SliderRow label="Volume" value={t.sound.gain} min={0} max={2} step={0.05} format={pct} disabled={t.sound.isMuted} onChange={(v) => commit((t) => void (t.sound.gain = v), "gain")} />
      </Section>
      {t.soundTracks.length === 0 && <p className="i-note">This recording has no sound.</p>}
      {t.soundTracks.map((track, i) => (
        <Section key={track.id} title={track.name || (track.source === "microphone" ? "Microphone" : "System audio")} trailing={<Switch small checked={!track.style.isMuted} onChange={(v) => commit((t) => void (t.soundTracks[i].style.isMuted = !v))} label="Track on" />}>
          <SliderRow label="Volume" value={track.style.gain} min={0} max={2} step={0.05} format={pct} disabled={track.style.isMuted || t.sound.isMuted} onChange={(v) => commit((t) => void (t.soundTracks[i].style.gain = v), `gain-${track.id}`)} />
        </Section>
      ))}
    </>
  );
}
