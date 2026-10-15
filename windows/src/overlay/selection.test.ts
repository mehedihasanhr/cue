import { describe, expect, it } from "vitest";
import { clamp, isClick, rectFrom, snap, square, windowAt } from "./selection";

describe("selection", () => {
  it("makes a rectangle from any two corners", () => {
    expect(rectFrom({ x: 50, y: 10 }, { x: 10, y: 40 })).toEqual({ x: 10, y: 10, width: 40, height: 30 });
  });

  it("finds the frontmost window", () => {
    const windows = [
      { x: 100, y: 100, width: 50, height: 50 },
      { x: 0, y: 0, width: 400, height: 400 },
    ];
    expect(windowAt({ x: 120, y: 120 }, windows)).toBe(0);
    expect(windowAt({ x: 10, y: 10 }, windows)).toBe(1);
    expect(windowAt({ x: 500, y: 10 }, windows)).toBe(-1);
  });

  it("snaps each axis to the nearest edge in range", () => {
    const windows = [{ x: 100, y: 200, width: 300, height: 100 }];
    expect(snap({ x: 105, y: 296 }, windows, 8)).toEqual({ x: 100, y: 300 });
    expect(snap({ x: 120, y: 250 }, windows, 8)).toEqual({ x: 120, y: 250 });
  });

  it("squares in the drag's direction", () => {
    expect(square({ x: 100, y: 100 }, { x: 40, y: 130 })).toEqual({ x: 40, y: 160 });
  });

  it("clamps to the display and rejects slivers", () => {
    expect(clamp({ x: -10, y: 5.4, width: 50, height: 20 }, 30, 100)).toEqual({ x: 0, y: 5, width: 30, height: 20 });
    expect(clamp({ x: 10, y: 10, width: 1, height: 50 }, 100, 100)).toBeNull();
  });

  it("treats tiny movements as clicks, scaled by the display", () => {
    expect(isClick({ x: 0, y: 0 }, { x: 4, y: 0 }, 1.5)).toBe(true);
    expect(isClick({ x: 0, y: 0 }, { x: 4, y: 0 }, 1)).toBe(false);
  });
});
