// The edit — the Mac's `Timeline` (TimelineKit), as `project.json` stores it. Times on
// disk are CMTime objects; here they are seconds. Fields this port does not use yet
// (blurs, captions, annotations…) are kept as they were read and written back, so a
// project made on the Mac survives being opened here.

/** CMTime as Swift encodes it. */
export type CMTime = { value: number; timescale: number; flags?: number; epoch?: number };
export const TIMESCALE = 600;

export function seconds(t: CMTime | undefined | null): number {
  if (!t || !t.timescale) return 0;
  return t.value / t.timescale;
}

export function cmtime(s: number): CMTime {
  return { epoch: 0, flags: 1, timescale: TIMESCALE, value: Math.round(s * TIMESCALE) };
}

export type RGBA = { r: number; g: number; b: number; a: number };
export type Point = [number, number];

export type Background =
  | { kind: "color"; color: RGBA }
  | { kind: "gradient"; from: RGBA; to: RGBA; angle: number }
  | { kind: "wallpaper"; id: string }
  | { kind: "image"; path: string }
  | { kind: "transparent" }
  /** A background this port can't draw yet (animated, video, custom gradient): kept as read. */
  | { kind: "other"; raw: unknown };

export type Aspect = "source" | "wide16x9" | "square" | "vertical9x16" | "classic4x3" | "portrait4x5" | "portrait3x4" | "wide16x10" | "custom";
export const ASPECT_RATIOS: Record<Exclude<Aspect, "source" | "custom">, number> = {
  wide16x9: 16 / 9,
  square: 1,
  vertical9x16: 9 / 16,
  classic4x3: 4 / 3,
  portrait4x5: 4 / 5,
  portrait3x4: 3 / 4,
  wide16x10: 16 / 10,
};

export type FrameStyle = {
  padding: number;
  cornerRadius: number;
  shadowRadius: number;
  shadowOpacity: number;
  backgroundBlur: number;
  aspect: Aspect;
  customAspect: { width: number; height: number };
  /** Normalised, top-left origin. */
  crop: { x: number; y: number; width: number; height: number } | null;
  borderWidth: number;
  borderColor: RGBA;
  background: Background;
};

export type ClickStyle = "ring" | "ripple" | "glow";
export type CursorStyle = {
  isVisible: boolean;
  scale: number;
  smoothing: number;
  clickEffect: boolean;
  motionBlur: boolean;
  sizeIsIndependentOfZoom: boolean;
  clickHighlight: boolean;
  clickColor: RGBA;
  clickSize: number;
  usesRecordedArtwork: boolean;
  hidesWhenIdle: boolean;
  idleDelay: number;
  alwaysArrow: boolean;
  steadiesShape: boolean;
  clickStyle: ClickStyle;
};

export type CameraStyle = {
  steadiness: number;
  follow: number;
  safeArea: number;
  zoomsWholeFrame: boolean;
  glidesBetweenZooms: boolean;
  keepsZoomedInFor: number;
  motionBlur: boolean;
  wholeVideoZoom: number;
  zoomSpeed: "slow" | "medium" | "fast";
};

export type Easing = "spring" | "linear" | "easeInOut";
export type ZoomSource = "manual" | "click" | "typing" | "field" | "window" | "application";
export type Zoom = {
  id: string;
  start: number;
  duration: number;
  scale: number;
  center: Point;
  easing: Easing;
  transition: number;
  transitionIn?: number;
  transitionOut?: number;
  followsCursor: boolean;
  source?: ZoomSource;
  isLocked: boolean;
  isEnabled: boolean;
  isEdited: boolean;
  isInstant: boolean;
};

export type Clip = {
  id: string;
  sourceStart: number;
  sourceDuration: number;
  /** Source seconds per timeline second, 0.25…8. */
  speed: number;
  /** A freeze frame or title's length; not handled by this port yet. */
  hold?: number;
};

export type SoundStyle = { isMuted: boolean; gain: number; cleansVoice: boolean; evensVolume: boolean };
export type SoundTrack = { id: string; source: "systemAudio" | "microphone"; name: string; path: string; deviceID?: string; style: SoundStyle };

export type Timeline = {
  sourceDuration: number;
  clips: Clip[];
  zooms: Zoom[];
  style: FrameStyle;
  cursor: CursorStyle;
  camera: CameraStyle;
  sound: SoundStyle;
  soundTracks: SoundTrack[];
  /** Everything else the file had, written back untouched. */
  rest: Record<string, unknown>;
};

export const uuid = () => crypto.randomUUID().toUpperCase();

export const WHITE: RGBA = { r: 1, g: 1, b: 1, a: 1 };
export const DEFAULT_GRADIENT: Background = {
  kind: "gradient",
  from: { r: 0.36, g: 0.42, b: 0.85, a: 1 },
  to: { r: 0.15, g: 0.16, b: 0.35, a: 1 },
  angle: 0.25,
};

export const defaultStyle = (): FrameStyle => ({
  padding: 0.06,
  cornerRadius: 0.02,
  shadowRadius: 0.03,
  shadowOpacity: 0.45,
  backgroundBlur: 0,
  aspect: "source",
  customAspect: { width: 3, height: 2 },
  crop: null,
  borderWidth: 0,
  borderColor: WHITE,
  background: DEFAULT_GRADIENT,
});

export const defaultCursor = (): CursorStyle => ({
  isVisible: true,
  scale: 1.4,
  smoothing: 0.6,
  clickEffect: true,
  motionBlur: false,
  sizeIsIndependentOfZoom: true,
  clickHighlight: true,
  clickColor: WHITE,
  clickSize: 0.07,
  usesRecordedArtwork: true,
  hidesWhenIdle: false,
  idleDelay: 2,
  alwaysArrow: false,
  steadiesShape: true,
  clickStyle: "ring",
});

export const defaultCamera = (): CameraStyle => ({
  steadiness: 0.7,
  follow: 1,
  safeArea: 0.85,
  zoomsWholeFrame: true,
  glidesBetweenZooms: true,
  keepsZoomedInFor: 0,
  motionBlur: true,
  wholeVideoZoom: 1,
  zoomSpeed: "medium",
});

export const ZOOM_SPEEDS = { slow: 1.2, medium: 0.9, fast: 0.6 } as const;

export const defaultSound = (): SoundStyle => ({ isMuted: false, gain: 1, cleansVoice: false, evensVolume: false });

export function newZoom(start: number, duration: number, patch: Partial<Zoom> = {}): Zoom {
  return {
    id: uuid(),
    start,
    duration,
    scale: 2,
    center: [0.5, 0.5],
    easing: "spring",
    transition: 0.9,
    followsCursor: true,
    isLocked: false,
    isEnabled: true,
    isEdited: false,
    isInstant: false,
    ...patch,
  };
}

/** A fresh edit of a whole recording. */
export function newTimeline(duration: number, soundTracks: SoundTrack[]): Timeline {
  return {
    sourceDuration: duration,
    clips: [{ id: uuid(), sourceStart: 0, sourceDuration: duration, speed: 1 }],
    zooms: [],
    style: defaultStyle(),
    cursor: defaultCursor(),
    camera: defaultCamera(),
    sound: defaultSound(),
    soundTracks,
    rest: {},
  };
}

// MARK: - Reading and writing project.json

type Json = Record<string, unknown>;
const obj = (v: unknown): Json => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : {});
const num = (v: unknown, fallback: number, min = -Infinity, max = Infinity) => (typeof v === "number" && Number.isFinite(v) ? Math.min(max, Math.max(min, v)) : fallback);
const bool = (v: unknown, fallback: boolean) => (typeof v === "boolean" ? v : fallback);
const str = <T extends string>(v: unknown, allowed: readonly T[], fallback: T): T => (allowed.includes(v as T) ? (v as T) : fallback);

function color(v: unknown, fallback: RGBA): RGBA {
  const c = obj(v);
  return typeof c.r === "number" ? { r: num(c.r, 0), g: num(c.g, 0), b: num(c.b, 0), a: num(c.a, 1) } : fallback;
}

/** Swift's enum-with-associated-values: `{"gradient":{"from":…}}`, `{"color":{"_0":…}}`. */
function readBackground(v: unknown): Background {
  const o = obj(v);
  const [key] = Object.keys(o);
  const inner = obj(o[key]);
  switch (key) {
    case "color": return { kind: "color", color: color(inner._0, WHITE) };
    case "gradient": return { kind: "gradient", from: color(inner.from, WHITE), to: color(inner.to, WHITE), angle: num(inner.angle, 0.25) };
    case "wallpaper": return { kind: "wallpaper", id: String(inner.id ?? "") };
    case "image": return { kind: "image", path: String(inner.path ?? "") };
    case "transparent": return { kind: "transparent" };
    case undefined: return DEFAULT_GRADIENT;
    default: return { kind: "other", raw: v };
  }
}

function writeBackground(b: Background): unknown {
  switch (b.kind) {
    case "color": return { color: { _0: b.color } };
    case "gradient": return { gradient: { from: b.from, to: b.to, angle: b.angle } };
    case "wallpaper": return { wallpaper: { id: b.id } };
    case "image": return { image: { path: b.path } };
    case "transparent": return { transparent: {} };
    case "other": return b.raw;
  }
}

/** CGRect `[[x, y], [w, h]]`. */
function rect(v: unknown): FrameStyle["crop"] {
  if (!Array.isArray(v) || v.length !== 2) return null;
  const [[x, y], [w, h]] = v as [[number, number], [number, number]];
  return [x, y, w, h].every((n) => typeof n === "number") ? { x, y, width: w, height: h } : null;
}

export function readTimeline(raw: unknown, duration: number, soundTracks: SoundTrack[]): Timeline {
  const o = obj(raw);
  const base = newTimeline(duration, soundTracks);
  const known = ["formatVersion", "sourceDuration", "clips", "zooms", "style", "cursor", "camera", "sound", "soundTracks"];
  const rest: Json = {};
  for (const [k, v] of Object.entries(o)) if (!known.includes(k)) rest[k] = v;

  const s = obj(o.style);
  const d = base.style;
  const styleKeys = ["padding", "cornerRadius", "shadowRadius", "shadowOpacity", "backgroundBlur", "aspect", "customAspect", "crop", "borderWidth", "borderColor", "background"];
  const styleRest: Json = {};
  for (const [k, v] of Object.entries(s)) if (!styleKeys.includes(k)) styleRest[k] = v;
  if (Object.keys(styleRest).length) rest.__styleRest = styleRest;
  const crop = rect(obj(s.crop).rect);
  const style: FrameStyle = {
    padding: num(s.padding, d.padding, 0, 0.45),
    cornerRadius: num(s.cornerRadius, d.cornerRadius, 0, 0.5),
    shadowRadius: num(s.shadowRadius, d.shadowRadius, 0, 0.2),
    shadowOpacity: num(s.shadowOpacity, d.shadowOpacity, 0, 1),
    backgroundBlur: num(s.backgroundBlur, d.backgroundBlur, 0, 0.1),
    aspect: str(s.aspect, ["source", "wide16x9", "square", "vertical9x16", "classic4x3", "portrait4x5", "portrait3x4", "wide16x10", "custom"] as const, d.aspect),
    customAspect: { width: num(obj(s.customAspect).width, 3, 1, 100), height: num(obj(s.customAspect).height, 2, 1, 100) },
    crop,
    borderWidth: num(s.borderWidth, 0, 0, 0.03),
    borderColor: color(s.borderColor, WHITE),
    background: s.background === undefined ? d.background : readBackground(s.background),
  };

  const c = obj(o.cursor);
  const dc = base.cursor;
  const cursor: CursorStyle = {
    isVisible: bool(c.isVisible, dc.isVisible),
    scale: num(c.scale, dc.scale, 0.3, 6),
    smoothing: num(c.smoothing, dc.smoothing, 0, 1),
    clickEffect: bool(c.clickEffect, dc.clickEffect),
    motionBlur: bool(c.motionBlur, dc.motionBlur),
    sizeIsIndependentOfZoom: bool(c.sizeIsIndependentOfZoom, dc.sizeIsIndependentOfZoom),
    clickHighlight: bool(c.clickHighlight, dc.clickHighlight),
    clickColor: color(c.clickColor, dc.clickColor),
    clickSize: num(c.clickSize, dc.clickSize, 0.01, 0.3),
    usesRecordedArtwork: bool(c.usesRecordedArtwork, dc.usesRecordedArtwork),
    hidesWhenIdle: bool(c.hidesWhenIdle, dc.hidesWhenIdle),
    idleDelay: num(c.idleDelay, dc.idleDelay, 0.5, 10),
    alwaysArrow: bool(c.alwaysArrow, dc.alwaysArrow),
    // An older file without the key keeps the shape as recorded (the Mac's rule).
    steadiesShape: o.cursor === undefined ? dc.steadiesShape : bool(c.steadiesShape, false),
    clickStyle: str(c.clickStyle, ["ring", "ripple", "glow"] as const, dc.clickStyle),
  };

  const m = obj(o.camera);
  const dm = base.camera;
  const missingCamera = o.camera === undefined && raw !== undefined && raw !== null;
  const camera: CameraStyle = {
    steadiness: num(m.steadiness, dm.steadiness, 0, 5),
    follow: num(m.follow, dm.follow, 0, 1),
    safeArea: num(m.safeArea, dm.safeArea, 0.05, 1),
    zoomsWholeFrame: bool(m.zoomsWholeFrame, dm.zoomsWholeFrame),
    // Projects saved before gliding existed keep their cuts (the Mac's rule).
    glidesBetweenZooms: missingCamera ? false : bool(m.glidesBetweenZooms, false),
    keepsZoomedInFor: num(m.keepsZoomedInFor, 0, 0, 30),
    motionBlur: missingCamera ? false : bool(m.motionBlur, false),
    wholeVideoZoom: num(m.wholeVideoZoom, 1, 1, 4),
    zoomSpeed: str(m.zoomSpeed, ["slow", "medium", "fast"] as const, "medium"),
  };

  const clips: Clip[] = (Array.isArray(o.clips) ? o.clips : [])
    .map((x) => obj(x))
    .filter((x) => x.sourceStart && x.sourceDuration)
    .map((x) => {
      const clip: Clip = { id: String(x.id ?? uuid()), sourceStart: seconds(x.sourceStart as CMTime), sourceDuration: seconds(x.sourceDuration as CMTime), speed: num(x.speed, 1, 0.25, 8) };
      if (x.hold) clip.hold = seconds(x.hold as CMTime);
      return clip;
    });

  const zooms: Zoom[] = (Array.isArray(o.zooms) ? o.zooms : []).map((x) => {
    const z = obj(x);
    const zoom = newZoom(seconds(z.start as CMTime), seconds(z.duration as CMTime), {
      id: String(z.id ?? uuid()),
      scale: num(z.scale, 2, 0.5, 8),
      center: Array.isArray(z.center) ? [num(z.center[0], 0.5), num(z.center[1], 0.5)] : [0.5, 0.5],
      easing: str(z.easing, ["spring", "linear", "easeInOut"] as const, "spring"),
      transition: z.transition ? seconds(z.transition as CMTime) : 0.9,
      followsCursor: bool(z.followsCursor, true),
      source: z.source === undefined ? undefined : str(z.source, ["manual", "click", "typing", "field", "window", "application"] as const, "manual"),
      isLocked: bool(z.isLocked, false),
      isEnabled: bool(z.isEnabled, true),
      isEdited: bool(z.isEdited, false),
      isInstant: bool(z.isInstant, false),
    });
    if (z.transitionIn) zoom.transitionIn = seconds(z.transitionIn as CMTime);
    if (z.transitionOut) zoom.transitionOut = seconds(z.transitionOut as CMTime);
    return zoom;
  });

  const so = obj(o.sound);
  const tracks: SoundTrack[] = Array.isArray(o.soundTracks) && o.soundTracks.length
    ? (o.soundTracks as Json[]).map((t) => ({
        id: String(t.id ?? uuid()),
        source: t.source === "microphone" ? "microphone" : "systemAudio",
        name: String(t.name ?? ""),
        path: String(t.path ?? ""),
        deviceID: t.deviceID as string | undefined,
        style: { isMuted: bool(obj(t.style).isMuted, false), gain: num(obj(t.style).gain, 1, 0, 2), cleansVoice: false, evensVolume: false },
      }))
    : soundTracks;

  return {
    sourceDuration: seconds(o.sourceDuration as CMTime) || duration,
    clips: clips.length ? clips : base.clips,
    zooms,
    style,
    cursor,
    camera,
    sound: { isMuted: bool(so.isMuted, false), gain: num(so.gain, 1, 0, 2), cleansVoice: bool(so.cleansVoice, false), evensVolume: bool(so.evensVolume, false) },
    soundTracks: tracks,
    rest,
  };
}

export function writeTimeline(t: Timeline): Json {
  const time = (s: number) => cmtime(s);
  const { __styleRest, ...rest } = t.rest;
  return {
    ...rest,
    formatVersion: 1,
    sourceDuration: time(t.sourceDuration),
    clips: t.clips.map((c) => ({ id: c.id, sourceStart: time(c.sourceStart), sourceDuration: time(c.sourceDuration), speed: c.speed, ...(c.hold ? { hold: time(c.hold) } : {}) })),
    zooms: t.zooms.map((z) => ({
      id: z.id,
      start: time(z.start),
      duration: time(z.duration),
      scale: z.scale,
      center: z.center,
      easing: z.easing,
      transition: time(z.transition),
      ...(z.transitionIn !== undefined ? { transitionIn: time(z.transitionIn) } : {}),
      ...(z.transitionOut !== undefined ? { transitionOut: time(z.transitionOut) } : {}),
      followsCursor: z.followsCursor,
      ...(z.source ? { source: z.source } : {}),
      isLocked: z.isLocked,
      isEnabled: z.isEnabled,
      isEdited: z.isEdited,
      isInstant: z.isInstant,
    })),
    style: {
      ...obj(__styleRest),
      padding: t.style.padding,
      cornerRadius: t.style.cornerRadius,
      shadowRadius: t.style.shadowRadius,
      shadowOpacity: t.style.shadowOpacity,
      backgroundBlur: t.style.backgroundBlur,
      aspect: t.style.aspect,
      customAspect: t.style.customAspect,
      ...(t.style.crop ? { crop: { rect: [[t.style.crop.x, t.style.crop.y], [t.style.crop.width, t.style.crop.height]] } } : {}),
      borderWidth: t.style.borderWidth,
      borderColor: t.style.borderColor,
      background: writeBackground(t.style.background),
    },
    cursor: { ...t.cursor },
    camera: { ...t.camera },
    sound: { ...t.sound },
    soundTracks: t.soundTracks.map((s) => ({ id: s.id, source: s.source, name: s.name, path: s.path, ...(s.deviceID ? { deviceID: s.deviceID } : {}), style: s.style })),
  };
}
