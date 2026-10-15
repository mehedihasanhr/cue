// Where the camera looks — the Mac's `ZoomRegion.scale(at:)`, `ZoomGlide`, `ZoomFraming`
// and `SceneBuilder.framedCamera`. Centres are fractions of the (cropped) picture from its
// top left. The same function serves the preview and the export, so they cannot disagree.

import { sourceTime } from "./clips";
import type { CursorTrack } from "./cursor";
import type { Easing, Point, Timeline, Zoom } from "./timeline";

export const MAX_SCALE = 8;
export const MIN_SCALE = 0.5;

export function ease(easing: Easing, t: number): number {
  t = Math.min(1, Math.max(0, t));
  switch (easing) {
    case "linear":
      return t;
    case "easeInOut":
      return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
    case "spring": {
      // A critically damped spring, stretched to arrive exactly at 1.
      const w = 6;
      return Math.min(1, (1 - (1 + w * t) * Math.exp(-w * t)) / (1 - (1 + w) * Math.exp(-w)));
    }
  }
}
const easeLeaving = (easing: Easing, p: number) => 1 - ease(easing, 1 - Math.min(1, Math.max(0, p)));

export function ramps(z: Zoom): { in: number; out: number } {
  if (z.isInstant) return { in: 0, out: 0 };
  const wantIn = Math.max(0, z.transitionIn ?? z.transition);
  const wantOut = Math.max(0, z.transitionOut ?? z.transition);
  const total = wantIn + wantOut;
  if (total <= z.duration || total <= 0) return { in: wantIn, out: wantOut };
  const share = z.duration / total;
  return { in: wantIn * share, out: wantOut * share };
}

/** How far in a zoom has the camera at `time`; 1 outside it. */
export function zoomScale(z: Zoom, time: number): number {
  const end = z.start + z.duration;
  if (!z.isEnabled || time < z.start || time >= end) return 1;
  const r = ramps(z);
  const rising = r.in > 0 ? (time - z.start) / r.in : 1;
  const falling = r.out > 0 ? (end - time) / r.out : 1;
  const eased = rising <= falling ? ease(z.easing, rising) : easeLeaving(z.easing, falling);
  return 1 + (z.scale - 1) * eased;
}

const strength = (scale: number) => Math.abs(Math.log2(Math.max(scale, 1e-6)));

// MARK: - Framing

export const halfSide = (scale: number) => 0.5 / Math.min(MAX_SCALE, Math.max(1, scale));

export function honoured(c: Point, scale: number): Point {
  const h = halfSide(scale);
  return [Math.min(1 - h, Math.max(h, c[0])), Math.min(1 - h, Math.max(h, c[1]))];
}

/** Keeps the shot on the picture; below 1× keeps the shrunken picture in its hole. */
export function cameraCenter(c: Point, scale: number): Point {
  if (scale >= 1) return honoured(c, scale);
  const reach = 0.5 / Math.max(scale, MIN_SCALE);
  const low = Math.max(0, 1 - reach);
  const high = Math.min(1, reach);
  return [Math.min(high, Math.max(low, c[0])), Math.min(high, Math.max(low, c[1]))];
}

/** Between two depths one point holds still while the picture grows round it. */
export function dolly(from: { scale: number; center: Point }, to: { scale: number; center: Point }, scale: number, progress: number): Point {
  progress = Math.min(1, Math.max(0, progress));
  if (Math.abs(to.scale - from.scale) <= 0.05 || scale <= 0) {
    return [from.center[0] + (to.center[0] - from.center[0]) * progress, from.center[1] + (to.center[1] - from.center[1]) * progress];
  }
  const axis = (c0: number, c1: number) => {
    const fixed = (c1 * to.scale - c0 * from.scale) / (to.scale - from.scale);
    return fixed - ((fixed - c0) * from.scale) / scale;
  };
  return [axis(from.center[0], to.center[0]), axis(from.center[1], to.center[1])];
}

/** The square a zoom frames, as fractions of the picture. */
export function zoomArea(z: Zoom): { x: number; y: number; side: number } {
  const h = halfSide(z.scale);
  const c = honoured(z.center, z.scale);
  return { x: c[0] - h, y: c[1] - h, side: h * 2 };
}

// MARK: - Glides

type Glide = { from: Zoom; to: Zoom; start: number; end: number; moveStart: number };

function glideBetween(from: Zoom, to: Zoom, kept: number): Glide | null {
  if (!from.isEnabled || !to.isEnabled || from.isInstant || to.isInstant || from.duration <= 0 || to.duration <= 0) return null;
  const fromEnd = from.start + from.duration;
  const gap = to.start - fromEnd;
  if (gap < 0) return null;
  const rf = ramps(from);
  const rt = ramps(to);
  const start = fromEnd - rf.out;
  const end = to.start + rt.in;
  if (gap < rf.out + rt.in) return { from, to, start, end, moveStart: start };
  if (kept > 0 && gap <= kept) return { from, to, start, end, moveStart: Math.min(Math.max(to.start - rf.out, start), end) };
  return null;
}

export function glides(zooms: Zoom[], kept: number): Glide[] {
  const lane = zooms.filter((z) => z.isEnabled && z.duration > 0).sort((a, b) => a.start - b.start);
  const out: Glide[] = [];
  let reach = -Infinity;
  for (let i = 1; i < lane.length; i++) {
    const from = lane[i - 1];
    const to = lane[i];
    const g = glideBetween(from, to, kept);
    const ok = g && reach <= g.start && !(i + 1 < lane.length && lane[i + 1].start < g.end);
    reach = Math.max(reach, from.start + from.duration);
    if (ok) out.push(g!);
  }
  return out;
}

const glideProgress = (g: Glide, time: number) => {
  const moving = g.end - g.moveStart;
  if (moving <= 0) return time < g.end ? 0 : 1;
  return ease(g.to.easing, (time - g.moveStart) / moving);
};

// MARK: - The camera

export type Camera = { zoom: number; center: Point };

/** What the camera needs to know about the picture: its size and the crop. */
export type Picture = {
  /** Video pixels. */
  width: number;
  height: number;
  /** Points to pixels. */
  displayScale: number;
  /** Normalised crop of the recording, top-left origin. */
  crop: { x: number; y: number; width: number; height: number };
};

/** A recorded point (points) as a fraction of the cropped picture; null outside it. */
export function normalised(p: [number, number], pic: Picture): Point | null {
  const u = ((p[0] * pic.displayScale) / pic.width - pic.crop.x) / pic.crop.width;
  const v = ((p[1] * pic.displayScale) / pic.height - pic.crop.y) / pic.crop.height;
  return u >= 0 && u <= 1 && v >= 0 && v <= 1 ? [u, v] : null;
}

function normalisedClamped(p: [number, number], pic: Picture): Point {
  const u = ((p[0] * pic.displayScale) / pic.width - pic.crop.x) / pic.crop.width;
  const v = ((p[1] * pic.displayScale) / pic.height - pic.crop.y) / pic.crop.height;
  return [Math.min(1, Math.max(0, u)), Math.min(1, Math.max(0, v))];
}

function nudged(c: Point, p: Point, reach: number, claim: number): Point {
  const kx = Math.min(Math.max(c[0], p[0] - reach), p[0] + reach);
  const ky = Math.min(Math.max(c[1], p[1] - reach), p[1] + reach);
  return [c[0] + (kx - c[0]) * claim, c[1] + (ky - c[1]) * claim];
}

export class CameraRig {
  private glideCache: { key: unknown[]; glides: Glide[] } | null = null;
  constructor(
    private readonly track: CursorTrack | null,
    private readonly pic: Picture,
  ) {}

  private glidesFor(t: Timeline): Glide[] {
    const key = [t.zooms, t.camera.keepsZoomedInFor];
    if (!this.glideCache || this.glideCache.key[0] !== key[0] || this.glideCache.key[1] !== key[1]) {
      this.glideCache = { key, glides: glides(t.zooms, t.camera.keepsZoomedInFor) };
    }
    return this.glideCache.glides;
  }

  /** The pointer where it is drawn, as recorded (smoothing is in the track). */
  private pointer(t: Timeline, time: number): [number, number] | null {
    if (!this.track || this.track.isEmpty) return null;
    return this.track.position(sourceTime(t, time));
  }

  camera(t: Timeline, time: number, held?: Zoom, following = 1): Camera {
    const base = t.camera.wholeVideoZoom;
    if (!held && t.camera.glidesBetweenZooms) {
      const glide = this.glidesFor(t).find((g) => time >= g.start && time < g.end);
      if (glide) {
        const progress = glideProgress(glide, time);
        const leaving = this.camera(t, time, glide.from, 1 - progress);
        const arriving = this.camera(t, time, glide.to, progress);
        const raw = glide.from.scale + (glide.to.scale - glide.from.scale) * progress;
        const scale = Math.min(Math.max(raw, Math.min(glide.from.scale, glide.to.scale)), Math.max(glide.from.scale, glide.to.scale)) * base;
        const center = dolly({ scale: glide.from.scale * base, center: leaving.center }, { scale: glide.to.scale * base, center: arriving.center }, scale, progress);
        return this.settled(t, time, center, scale);
      }
    }

    let best: { scale: number; zoom: Zoom } | null = held ? { scale: held.scale, zoom: held } : null;
    if (!held) {
      for (const z of t.zooms) {
        const s = zoomScale(z, time);
        if (s === 1) continue;
        if (!best || strength(s) > strength(best.scale)) best = { scale: s, zoom: z };
      }
    }
    if (!best) {
      if (base <= 1) return { zoom: 1, center: [0.5, 0.5] };
      return this.settled(t, time, this.heldShot(t, time, base), base);
    }

    const camera = t.camera;
    const scale = best.scale * base;
    const target = best.zoom.scale * base;
    const arrived = Math.abs(target - base) > 1e-4 ? Math.min(1, Math.max(0, (scale - base) / (target - base))) : 1;
    let center: Point = best.zoom.center;
    const half = halfSide(target);

    if (target > 1 && best.zoom.followsCursor && camera.follow > 0 && t.cursor.isVisible && this.track && !this.track.isEmpty) {
      const claim = camera.follow * arrived * Math.min(1, Math.max(0, following));
      const source = sourceTime(t, time);
      const averaged = this.track.averagePosition(source, camera.steadiness);
      const a = averaged && normalised(averaged, this.pic);
      if (a) center = nudged(center, a, half * camera.safeArea, claim);
      const live = this.pointer(t, time);
      const l = live && normalised(live, this.pic);
      if (l) center = nudged(center, l, half * camera.safeArea, claim);
    }
    const aim = cameraCenter(center, target);
    if (scale < 1 || target < 1) return this.settled(t, time, aim, scale);

    const before = base > 1 ? { scale: base, center: cameraCenter(this.heldShot(t, time, base), base) } : { scale: 1, center: [0.5, 0.5] as Point };
    center = dolly(before, { scale: target, center: aim }, scale, arrived);
    return this.settled(t, time, center, scale);
  }

  /** A video held zoomed in, with no zoom deciding: aim a beat behind the pointer. */
  private heldShot(t: Timeline, time: number, scale: number): Point {
    const middle: Point = [0.5, 0.5];
    const camera = t.camera;
    if (scale <= 1 || camera.follow <= 0 || !t.cursor.isVisible || !this.track || this.track.isEmpty) return middle;
    const claim = camera.follow;
    const half = halfSide(scale);
    const source = sourceTime(t, time);
    const window = Math.max(1.5, camera.steadiness * 2);
    let x = 0;
    let y = 0;
    let weights = 0;
    for (let age = 0; age < window; age += 1 / 60) {
      const p = this.track.position(source - age);
      if (!p) continue;
      const c = normalisedClamped(p, this.pic);
      const w = (1 - age / window) ** 2;
      x += c[0] * w;
      y += c[1] * w;
      weights += w;
    }
    let center = middle;
    if (weights > 0) center = [0.5 + (x / weights - 0.5) * claim, 0.5 + (y / weights - 0.5) * claim];
    const averaged = this.track.averagePosition(source, camera.steadiness);
    const a = averaged && normalised(averaged, this.pic);
    if (a) center = nudged(center, a, half * camera.safeArea, claim);
    const live = this.pointer(t, time);
    const l = live && normalised(live, this.pic);
    if (l) center = nudged(center, l, half * camera.safeArea, claim);
    return center;
  }

  /** Every shot ends here: a drawn pointer stays in it, and it stays on the picture. */
  private settled(t: Timeline, time: number, center: Point, scale: number): Camera {
    if (scale > 1 && t.camera.follow > 0 && t.cursor.isVisible) {
      const live = this.pointer(t, time);
      if (live) center = nudged(center, normalisedClamped(live, this.pic), halfSide(scale) * 0.98, 1);
    }
    return { zoom: scale, center: cameraCenter(center, scale) };
  }
}
