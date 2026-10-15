import { describe, expect, it } from "vitest";
import { display, fromEvent } from "./accelerator";

const press = (code: string, mods: Partial<Record<"ctrlKey" | "altKey" | "shiftKey" | "metaKey", boolean>> = {}) => ({
  code, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...mods,
});

describe("accelerator", () => {
  it("builds modifiers in a fixed order", () => {
    expect(fromEvent(press("Digit4", { shiftKey: true, altKey: true }))).toBe("Alt+Shift+4");
    expect(fromEvent(press("KeyT", { ctrlKey: true, shiftKey: true }))).toBe("Ctrl+Shift+T");
  });

  it("waits while only modifiers are held", () => {
    expect(fromEvent(press("AltLeft", { altKey: true }))).toBeNull();
  });

  it("refuses keys that would swallow typing", () => {
    expect(fromEvent(press("KeyA"))).toBeNull();
    expect(fromEvent(press("KeyA", { shiftKey: true }))).toBeNull();
  });

  it("allows Print Screen and function keys alone", () => {
    expect(fromEvent(press("PrintScreen"))).toBe("PrintScreen");
    expect(fromEvent(press("F9"))).toBe("F9");
  });

  it("reads Super as the Windows key", () => {
    expect(display("Super+Shift+S")).toEqual(["Win", "Shift", "S"]);
  });
});
