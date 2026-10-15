import { describe, expect, it } from "vitest";
import { contentOffset, DEFAULT_BACKGROUND, layout, type Doc } from "./document";

const doc = (patch: Partial<Doc> = {}): Doc => ({
  width: 400, height: 300, scale: 1, annotations: [], crop: null, background: null, nextCounter: 1, ...patch,
});

describe("layout", () => {
  it("is the image alone without a background", () => {
    expect(layout(doc())).toMatchObject({ width: 400, height: 300, image: { x: 0, y: 0 } });
  });

  it("pads and insets the card", () => {
    const l = layout(doc({ background: { ...DEFAULT_BACKGROUND, padding: 40, inset: 10 } }));
    expect(l.width).toBe(400 + 20 + 80);
    expect(l.card).toEqual({ x: 40, y: 40, width: 420, height: 320 });
    expect(l.image).toEqual({ x: 50, y: 50, width: 400, height: 300 });
  });

  it("grows to a ratio and aligns the card in the slack", () => {
    const l = layout(doc({ background: { ...DEFAULT_BACKGROUND, padding: 0, ratio: "square", alignment: { x: 0, y: 1 } } }));
    expect(l.width).toBe(400);
    expect(l.height).toBe(400);
    expect(l.card.y).toBe(100);
  });

  it("balances padding from the image size", () => {
    const l = layout(doc({ background: { ...DEFAULT_BACKGROUND, autoBalance: true } }));
    expect(l.card.x).toBe(32);
  });

  it("offsets annotations by the crop", () => {
    expect(contentOffset(doc({ crop: { x: 50, y: 20, width: 100, height: 100 } }))).toEqual({ x: -50, y: -20 });
  });
});
