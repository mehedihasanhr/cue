import { describe, expect, it } from "vitest";
import { CameraRig, cameraCenter, dolly, ease, glides, ramps, zoomScale } from "./camera";
import { clipDuration, deleteRange, duration, setSpeed, sourceTime, split, timelineTime, trim } from "./clips";
import { CursorTrack } from "./cursor";
import { placedOnTimeline, suggestClickZooms } from "./suggest";
import { newTimeline, newZoom, readTimeline, writeTimeline } from "./timeline";

describe("easing", () => {
  it("springs from rest to exactly 1", () => {
    expect(ease("spring", 0)).toBe(0);
    expect(ease("spring", 1)).toBeCloseTo(1, 12);
    expect(ease("spring", 0.5)).toBeGreaterThan(0.75);
  });
  it("eases in and out symmetrically", () => {
    expect(ease("easeInOut", 0.25) + ease("easeInOut", 0.75)).toBeCloseTo(1, 12);
  });
});

describe("a zoom", () => {
  it("shares a short region between its ramps", () => {
    expect(ramps(newZoom(0, 1))).toEqual({ in: 0.5, out: 0.5 });
    expect(ramps(newZoom(0, 4))).toEqual({ in: 0.9, out: 0.9 });
  });
  it("is in all the way between its ramps and out of it outside", () => {
    const z = newZoom(1, 4, { scale: 2 });
    expect(zoomScale(z, 0.5)).toBe(1);
    expect(zoomScale(z, 3)).toBeCloseTo(2, 9);
    expect(zoomScale(z, 5)).toBe(1);
    expect(zoomScale({ ...z, isEnabled: false }, 3)).toBe(1);
  });
  it("glides to a zoom close behind it", () => {
    const a = newZoom(0, 3);
    const b = newZoom(3.5, 3);
    expect(glides([a, b], 0)).toHaveLength(1);
    expect(glides([a, newZoom(8, 3)], 0)).toHaveLength(0);
  });
});

describe("framing", () => {
  it("keeps the shot on the picture", () => {
    expect(cameraCenter([0, 1], 2)).toEqual([0.25, 0.75]);
  });
  it("dollies about the point that stays put", () => {
    const from = { scale: 1, center: [0.5, 0.5] as [number, number] };
    const to = { scale: 2, center: [0.25, 0.25] as [number, number] };
    expect(dolly(from, to, 1, 0)).toEqual([0.5, 0.5]);
    const end = dolly(from, to, 2, 1);
    expect(end[0]).toBeCloseTo(0.25, 9);
  });
  it("frames a held zoom on its centre, and follows a pointer that leaves it", () => {
    const t = newTimeline(10, []);
    t.zooms = [newZoom(0, 10, { scale: 2, center: [0.3, 0.3], followsCursor: true })];
    const still = new CursorTrack([{ t: 0, x: 400, y: 300, shape: "arrow" }], []);
    const pic = { width: 1600, height: 1000, displayScale: 2, crop: { x: 0, y: 0, width: 1, height: 1 } };
    const shot = new CameraRig(still, pic).camera(t, 5);
    expect(shot.zoom).toBeCloseTo(2, 6);
    expect(shot.center[0]).toBeCloseTo(0.3, 6);
    // The pointer at the far right: the camera comes along to keep it in shot.
    const right = new CursorTrack([{ t: 0, x: 780, y: 150, shape: "arrow" }], []);
    expect(new CameraRig(right, pic).camera(t, 5).center[0]).toBeGreaterThan(0.6);
  });
});

describe("clips", () => {
  it("splits without changing the length, and maps time both ways", () => {
    const t = newTimeline(10, []);
    expect(split(t, 4)).toBe(true);
    expect(t.clips).toHaveLength(2);
    expect(duration(t)).toBeCloseTo(10, 9);
    setSpeed(t, 1, 2);
    expect(duration(t)).toBeCloseTo(7, 9);
    expect(sourceTime(t, 5)).toBeCloseTo(6, 9);
    expect(timelineTime(t, 6)).toBeCloseTo(5, 9);
  });
  it("closes the gap a delete leaves, and takes zooms with it", () => {
    const t = newTimeline(10, []);
    t.zooms = [newZoom(2.5, 1), newZoom(7, 2)];
    expect(deleteRange(t, 2, 4)).toBe(true);
    expect(duration(t)).toBeCloseTo(8, 9);
    expect(t.zooms).toHaveLength(1);
    expect(t.zooms[0].start).toBeCloseTo(5, 9);
  });
  it("trims within the recording", () => {
    const t = newTimeline(10, []);
    expect(trim(t, 0, "start", -3) + 0).toBe(0);
    trim(t, 0, "start", 2);
    expect(t.clips[0].sourceStart).toBe(2);
    expect(clipDuration(t.clips[0])).toBe(8);
  });
});

describe("the pointer", () => {
  it("smooths, but lands clicks where they were made", () => {
    const samples = Array.from({ length: 60 }, (_, i) => ({ t: i / 60, x: i % 2 ? 100 : 0, y: 0, shape: "arrow" }));
    const track = new CursorTrack(samples, [{ mouseDown: { button: 0, t: 0.5, x: 100, y: 0 } }]);
    const smooth = track.smoothed(0.8);
    expect(smooth.position(0.25)![0]).toBeGreaterThan(20);
    expect(smooth.position(0.25)![0]).toBeLessThan(80);
    expect(smooth.position(0.5)![0]).toBeCloseTo(100, 6);
  });
  it("reads the recorder's files", () => {
    const track = CursorTrack.parse('{"shape":"arrow","t":0,"x":1,"y":2}\n{"shape":"iBeam","t":1,"x":3,"y":4}\n{"sha', '{"mouseDown":{"button":0,"t":0.5,"x":2,"y":3}}\n');
    expect(track.samples).toHaveLength(3);
    expect(track.clicks).toEqual([{ t: 0.5, x: 2, y: 3, isSecondary: false }]);
  });
});

describe("zoom suggestions", () => {
  it("makes one zoom of a cluster of clicks", () => {
    const clicks = [1, 1.5, 2.2].map((t) => ({ t, x: 200, y: 150, isSecondary: false }));
    const zooms = suggestClickZooms(clicks, { width: 1440, height: 900 }, { x: 0, y: 0, width: 1, height: 1 }, 20);
    expect(zooms).toHaveLength(1);
    expect(zooms[0].scale).toBe(1.8);
    expect(zooms[0].start).toBeCloseTo(0.19, 6);
    const t = newTimeline(20, []);
    expect(placedOnTimeline(t, zooms)).toHaveLength(1);
  });
});

describe("project.json", () => {
  it("round-trips, keeping what it doesn't know", () => {
    const t = newTimeline(12.5, []);
    t.zooms = [newZoom(1, 2, { center: [0.2, 0.7] })];
    t.style.crop = { x: 0.1, y: 0.1, width: 0.5, height: 0.5 };
    const json = writeTimeline(t);
    const raw = JSON.parse(JSON.stringify({ ...json, captions: [{ id: "x" }], style: { ...(json.style as object), chrome: { kind: "macOS" } } }));
    const back = readTimeline(raw, 12.5, []);
    expect(back.zooms[0].center).toEqual([0.2, 0.7]);
    expect(back.style.crop).toEqual({ x: 0.1, y: 0.1, width: 0.5, height: 0.5 });
    const again = writeTimeline(back) as Record<string, unknown>;
    expect(again.captions).toEqual([{ id: "x" }]);
    expect((again.style as Record<string, unknown>).chrome).toEqual({ kind: "macOS" });
    expect((again.sourceDuration as { value: number }).value).toBe(7500);
  });
  it("reads a Mac gradient", () => {
    const t = readTimeline({ style: { background: { gradient: { from: { r: 1, g: 0, b: 0, a: 1 }, to: { r: 0, g: 0, b: 1, a: 1 }, angle: 0.1 } } } }, 3, []);
    expect(t.style.background).toMatchObject({ kind: "gradient", angle: 0.1 });
  });
});
