// The Mac's ShapeRecognizerTests, case for case.
import { describe, expect, it } from "vitest";
import { recognize, type P } from "./shapeRecognizer";

const p = (x: number, y: number): P => ({ x, y });

function stroke(corners: P[], step = 3, tremor = 1.5): P[] {
  const points: P[] = [];
  let n = 0;
  for (let c = 1; c < corners.length; c++) {
    const a = corners[c - 1], b = corners[c];
    const count = Math.max(1, Math.trunc(Math.hypot(b.x - a.x, b.y - a.y) / step));
    for (let i = 0; i < count; i++) {
      const t = i / count;
      n++;
      points.push(p(a.x + (b.x - a.x) * t + tremor * Math.sin(n * 0.7), a.y + (b.y - a.y) * t + tremor * Math.cos(n * 1.3)));
    }
  }
  points.push(corners[corners.length - 1]);
  return points;
}

function oval(center: P, rx: number, ry: number, turns = 1.05, wobble = 0.04): P[] {
  return Array.from({ length: 91 }, (_, i) => {
    const angle = (i / 90) * turns * 2 * Math.PI;
    const r = 1 + wobble * Math.sin(angle * 5);
    return p(center.x + rx * r * Math.cos(angle), center.y + ry * r * Math.sin(angle));
  });
}

describe("shape recognizer", () => {
  it("makes a straight stroke a line", () => {
    const shape = recognize(stroke([p(10, 10), p(210, 90)]));
    expect(shape?.kind).toBe("line");
    if (shape?.kind !== "line") return;
    expect(Math.abs(shape.start.x - 10)).toBeLessThan(3);
    expect(Math.abs(shape.end.x - 210)).toBeLessThan(3);
  });

  it("leaves a curve alone", () => {
    const arc = Array.from({ length: 41 }, (_, i) => p(100 + 80 * Math.cos((i / 40) * Math.PI), 100 - 80 * Math.sin((i / 40) * Math.PI)));
    expect(recognize(arc)).toBeNull();
  });

  it("makes a round stroke an ellipse", () => {
    const shape = recognize(oval(p(150, 150), 60, 60));
    expect(shape?.kind).toBe("ellipse");
    if (shape?.kind !== "ellipse") return;
    expect(Math.abs(shape.rect.x + shape.rect.width / 2 - 150)).toBeLessThan(6);
    expect(Math.abs(shape.rect.width - 120)).toBeLessThan(14);
  });

  it("makes a flat oval an ellipse", () => {
    expect(recognize(oval(p(200, 100), 120, 45))?.kind).toBe("ellipse");
  });

  it("makes an oval that stops short an ellipse", () => {
    expect(recognize(oval(p(100, 100), 50, 40, 0.93))?.kind).toBe("ellipse");
  });

  it("makes a box a rectangle", () => {
    const shape = recognize(stroke([p(20, 20), p(220, 22), p(218, 140), p(22, 138), p(21, 24)]));
    expect(shape?.kind).toBe("rectangle");
    if (shape?.kind !== "rectangle") return;
    expect(Math.abs(shape.rect.x - 20)).toBeLessThan(4);
    expect(Math.abs(shape.rect.y + shape.rect.height - 140)).toBeLessThan(4);
  });

  it("does not mistake a box for an ellipse", () => {
    expect(recognize(stroke([p(0, 0), p(100, 0), p(100, 100), p(0, 100), p(0, 4)]))?.kind).toBe("rectangle");
  });

  it("does not mistake a circle for a rectangle", () => {
    expect(recognize(oval(p(100, 100), 70, 70, 1.05, 0.02))?.kind).toBe("ellipse");
  });

  it("makes a shaft with one barb an arrow", () => {
    const shape = recognize(stroke([p(20, 100), p(220, 100), p(195, 82)]));
    expect(shape?.kind).toBe("arrow");
    if (shape?.kind !== "arrow") return;
    expect(Math.abs(shape.start.x - 20)).toBeLessThan(4);
    expect(Math.abs(shape.end.x - 220)).toBeLessThan(6);
  });

  it("makes a shaft with both barbs an arrow", () => {
    const shape = recognize(stroke([p(40, 200), p(200, 40), p(170, 45), p(200, 40), p(195, 70)]));
    expect(shape?.kind).toBe("arrow");
    if (shape?.kind !== "arrow") return;
    expect(Math.abs(shape.start.y - 200)).toBeLessThan(4);
    expect(Math.abs(shape.end.x - 200)).toBeLessThan(8);
  });

  it("leaves a zigzag alone", () => {
    expect(recognize(stroke([p(0, 0), p(40, 60), p(80, 0), p(120, 60), p(160, 0)]))).toBeNull();
  });

  it("leaves a vee alone", () => {
    expect(recognize(stroke([p(0, 0), p(60, 100), p(120, 0)]))).toBeNull();
  });

  it("ignores a tiny stroke", () => {
    expect(recognize(stroke([p(0, 0), p(8, 3)], 1, 0))).toBeNull();
  });

  it("leaves handwriting alone", () => {
    const squiggle = Array.from({ length: 81 }, (_, i) => {
      const t = (i / 80) * 4 * Math.PI;
      return p(20 * Math.cos(t) + i * 2.5, 20 * Math.sin(t));
    });
    expect(recognize(squiggle)).toBeNull();
  });
});
