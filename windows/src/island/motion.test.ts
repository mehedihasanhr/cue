import { describe, expect, it } from "vitest";
import { curves, notchPath } from "./motion";

describe("island motion", () => {
  it("draws the notch shape with its flares outside the body", () => {
    const d = notchPath(140, 22, 6, 12);
    expect(d.startsWith("M 0 0")).toBe(true);
    expect(d).toContain("152 0"); // 140 + 2 × 6
  });

  it("follows Settings › Island › Animation", () => {
    expect(curves("lively", false).open).toEqual({ kind: "spring", response: 0.36, damping: 0.82 });
    expect(curves("lively", true).open.kind).toBe("ease");
    expect(curves("none", false).close.kind).toBe("none");
  });
});
