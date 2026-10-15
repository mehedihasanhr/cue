// Auto zooms from the clicks — the click half of the Mac's `ZoomSuggester`. Clicks close
// together in time and space become one zoom aimed at their middle.

import { honoured, halfSide } from "./camera";
import { timelineTime } from "./clips";
import type { Click } from "./cursor";
import { newZoom, type Timeline, type Zoom } from "./timeline";

const TUNING = { clusterGap: 2.5, leadIn: 0.7, holdAfter: 1.2, minimumDuration: 1.5, maximumDuration: 12, transition: 0.9, scale: 1.8, spreadLimit: 900 };

/**
 * @param frame the recording in points, and the crop (normalised) of it that is shown.
 * @returns zooms in recording time.
 */
export function suggestClickZooms(clicks: Click[], frame: { width: number; height: number }, crop: { x: number; y: number; width: number; height: number }, duration: number): Zoom[] {
  const shown = { x: crop.x * frame.width, y: crop.y * frame.height, width: crop.width * frame.width, height: crop.height * frame.height };
  const inside = clicks.filter((c) => c.x >= shown.x && c.x <= shown.x + shown.width && c.y >= shown.y && c.y <= shown.y + shown.height).sort((a, b) => a.t - b.t);
  const t = TUNING;
  const regions: Zoom[] = [];
  let cluster: Click[] = [];

  const flush = () => {
    if (!cluster.length) return;
    const first = cluster[0];
    const last = cluster[cluster.length - 1];
    const start = Math.max(0, first.t - Math.max(t.leadIn, t.transition * 0.9));
    const end = Math.min(duration, last.t + t.holdAfter);
    const shortest = Math.max(t.minimumDuration, t.transition * 2 + 0.8);
    const length = Math.min(Math.max(end - start, shortest), t.maximumDuration);
    if (length > 0 && start < duration) {
      const mx = cluster.reduce((s, c) => s + c.x, 0) / cluster.length;
      const my = cluster.reduce((s, c) => s + c.y, 0) / cluster.length;
      const centre = honoured([(mx - shown.x) / shown.width, (my - shown.y) / shown.height], t.scale);
      regions.push(newZoom(start, Math.min(length, duration - start), { scale: t.scale, center: centre, transition: t.transition, source: "click" }));
    }
    cluster = [];
  };
  const belongs = (c: Click) => {
    const previous = cluster[cluster.length - 1];
    if (!previous) return true;
    if (c.t - previous.t > t.clusterGap) return false;
    const xs = [...cluster.map((p) => p.x), c.x];
    const ys = [...cluster.map((p) => p.y), c.y];
    return Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys)) <= t.spreadLimit;
  };
  for (const c of inside) {
    if (!belongs(c)) flush();
    cluster.push(c);
  }
  flush();
  return merged(regions, duration);
}

function merged(regions: Zoom[], duration: number): Zoom[] {
  const result: Zoom[] = [];
  const apart = (a: Zoom, b: Zoom) => {
    const reach = Math.min(halfSide(a.scale), halfSide(b.scale));
    return Math.abs(a.center[0] - b.center[0]) > reach || Math.abs(a.center[1] - b.center[1]) > reach;
  };
  for (const region of regions) {
    const last = result[result.length - 1];
    if (!last || region.start >= last.start + last.duration) {
      result.push(region);
      continue;
    }
    if (apart(last, region) && region.start - last.start >= TUNING.transition + 0.8) {
      last.duration = region.start - last.start;
      result.push(region);
      continue;
    }
    last.duration = Math.min(Math.max(last.start + last.duration, region.start + region.duration), duration) - last.start;
    last.center = apart(last, region) ? region.center : [(last.center[0] + region.center[0]) / 2, (last.center[1] + region.center[1]) / 2];
  }
  return result;
}

/** Zooms found in recording time, placed where that footage plays in the edit. */
export function placedOnTimeline(t: Timeline, zooms: Zoom[]): Zoom[] {
  return zooms.flatMap((z) => {
    const start = timelineTime(t, z.start);
    const end = timelineTime(t, Math.min(t.sourceDuration - 0.001, z.start + z.duration));
    if (start === null || end === null || end - start < 0.5) return [];
    return [{ ...z, start, duration: end - start }];
  });
}
