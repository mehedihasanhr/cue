// What footage plays and for how long — the Mac's `Timeline.clip(at:)`, `sourceTime`,
// `timelineTime` and `ClipSequence`. Regions (zooms) are in timeline time, so an edit
// that removes time carries them along.

import { uuid, type Clip, type Timeline } from "./timeline";

export const MIN_CLIP = 0.1;

export const clipDuration = (c: Clip) => (c.hold !== undefined ? c.hold : c.sourceDuration / c.speed);
export const duration = (t: Timeline) => t.clips.reduce((sum, c) => sum + clipDuration(c), 0);

/** The clip playing at a timeline time, and how far into it. */
export function clipAt(t: Timeline, time: number): { index: number; clip: Clip; offset: number; start: number } | null {
  let elapsed = 0;
  for (let index = 0; index < t.clips.length; index++) {
    const clip = t.clips[index];
    const next = elapsed + clipDuration(clip);
    if (time < next || index === t.clips.length - 1) {
      return { index, clip, offset: Math.max(0, Math.min(time - elapsed, clipDuration(clip))), start: elapsed };
    }
    elapsed = next;
  }
  return null;
}

/** Where a timeline time lands in the recording. */
export function sourceTime(t: Timeline, time: number): number {
  const at = clipAt(t, time);
  if (!at) return 0;
  return at.clip.hold !== undefined ? at.clip.sourceStart : at.clip.sourceStart + at.offset * at.clip.speed;
}

/** Where a moment of the recording plays on the timeline; null where it was cut. */
export function timelineTime(t: Timeline, source: number): number | null {
  let elapsed = 0;
  for (const clip of t.clips) {
    if (clip.hold === undefined && source >= clip.sourceStart && source < clip.sourceStart + clip.sourceDuration) {
      return elapsed + (source - clip.sourceStart) / clip.speed;
    }
    elapsed += clipDuration(clip);
  }
  return null;
}

/** The cut times (clip ends), from the first. */
export function cuts(t: Timeline): number[] {
  let elapsed = 0;
  return t.clips.map((c) => (elapsed += clipDuration(c)));
}

/** Cuts the clip at `time` in two; the timeline keeps its length. */
export function split(t: Timeline, time: number): boolean {
  const at = clipAt(t, time);
  if (!at) return false;
  const { index, clip, offset } = at;
  const length = clipDuration(clip);
  if (offset < MIN_CLIP || length - offset < MIN_CLIP) return false;
  const first = { ...clip };
  let second: Clip;
  if (clip.hold !== undefined) {
    first.hold = offset;
    second = { id: uuid(), sourceStart: clip.sourceStart, sourceDuration: 0, speed: 1, hold: clip.hold - offset };
  } else {
    const consumed = offset * clip.speed;
    first.sourceDuration = consumed;
    second = { id: uuid(), sourceStart: clip.sourceStart + consumed, sourceDuration: clip.sourceDuration - consumed, speed: clip.speed };
  }
  t.clips.splice(index, 1, first, second);
  return true;
}

function nearestCut(t: Timeline, time: number): number {
  let nearest = 0;
  let distance = Math.abs(time);
  for (const c of cuts(t)) {
    if (Math.abs(c - time) < distance) {
      distance = Math.abs(c - time);
      nearest = c;
    }
  }
  return nearest;
}

/** Removes a stretch of the timeline and closes the gap, regions and all. */
export function deleteRange(t: Timeline, start: number, end: number): boolean {
  start = Math.max(0, start);
  end = Math.min(duration(t), end);
  if (end <= start) return false;
  split(t, start);
  split(t, end);
  const from = nearestCut(t, start);
  const to = nearestCut(t, end);
  if (to <= from) return false;
  const kept: Clip[] = [];
  let removedStart: number | null = null;
  let removedEnd = 0;
  let elapsed = 0;
  for (const clip of t.clips) {
    const clipEnd = elapsed + clipDuration(clip);
    if (elapsed >= from - 1e-6 && clipEnd <= to + 1e-6) {
      if (removedStart === null) removedStart = elapsed;
      removedEnd = clipEnd;
    } else kept.push(clip);
    elapsed = clipEnd;
  }
  if (removedStart === null || !kept.length || kept.length === t.clips.length) return false;
  t.clips = kept;
  shiftRegions(t, removedStart, removedEnd);
  return true;
}

/** Deletes one clip (never the last). */
export function deleteClip(t: Timeline, index: number): boolean {
  if (t.clips.length < 2) return false;
  let start = 0;
  for (let i = 0; i < index; i++) start += clipDuration(t.clips[i]);
  const length = clipDuration(t.clips[index]);
  t.clips.splice(index, 1);
  shiftRegions(t, start, start + length);
  return true;
}

/**
 * A region wholly inside a removed stretch goes with it; one after it moves earlier; one
 * straddling it loses the overlap.
 */
function shiftRegions(t: Timeline, start: number, end: number) {
  const removed = end - start;
  t.zooms = t.zooms.flatMap((z) => {
    const zEnd = z.start + z.duration;
    if (z.start >= start && zEnd <= end) return [];
    if (z.start >= end) return [{ ...z, start: z.start - removed }];
    if (zEnd <= start) return [z];
    const overlap = Math.min(zEnd, end) - Math.max(z.start, start);
    const newStart = z.start < start ? z.start : start;
    const length = z.duration - overlap;
    return length >= MIN_CLIP ? [{ ...z, start: newStart, duration: length }] : [];
  });
}

/**
 * Changes a clip's speed. The regions after it move with the clip's new end; ones over it
 * scale with it.
 */
export function setSpeed(t: Timeline, index: number, speed: number) {
  const clip = t.clips[index];
  if (!clip || clip.hold !== undefined) return;
  let start = 0;
  for (let i = 0; i < index; i++) start += clipDuration(t.clips[i]);
  const before = clipDuration(clip);
  clip.speed = Math.min(8, Math.max(0.25, speed));
  const after = clipDuration(clip);
  const end = start + before;
  const ratio = after / before;
  const map = (time: number) => (time <= start ? time : time >= end ? time + after - before : start + (time - start) * ratio);
  t.zooms = t.zooms.map((z) => {
    const s = map(z.start);
    const e = map(z.start + z.duration);
    return { ...z, start: s, duration: Math.max(MIN_CLIP, e - s) };
  });
}

/**
 * Moves one edge of a clip: the start edge eats into or gives back the clip's beginning,
 * the end edge its end. `delta` in timeline seconds. Returns the delta actually applied.
 */
export function trim(t: Timeline, index: number, edge: "start" | "end", delta: number): number {
  const clip = t.clips[index];
  if (!clip || clip.hold !== undefined) return 0;
  const sourceDelta = delta * clip.speed;
  if (edge === "start") {
    const min = -clip.sourceStart; // can't reach before the recording
    const max = clip.sourceDuration - MIN_CLIP * clip.speed;
    const d = Math.min(max, Math.max(min, sourceDelta));
    clip.sourceStart += d;
    clip.sourceDuration -= d;
    return d / clip.speed;
  }
  const min = -(clip.sourceDuration - MIN_CLIP * clip.speed);
  const max = t.sourceDuration - (clip.sourceStart + clip.sourceDuration);
  const d = Math.min(max, Math.max(min, sourceDelta));
  clip.sourceDuration += d;
  return d / clip.speed;
}
