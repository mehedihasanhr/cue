// Keyboard shortcuts in Tauri's accelerator syntax ("Alt+Shift+4").

type KeyLike = { code: string; ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean };

const NAMED: Record<string, string> = {
  Space: "Space", Enter: "Enter", Tab: "Tab", Backspace: "Backspace", Delete: "Delete",
  Insert: "Insert", Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown",
  ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right",
  PrintScreen: "PrintScreen", Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]",
  Backslash: "\\", Semicolon: ";", Quote: "'", Comma: ",", Period: ".", Slash: "/", Backquote: "`",
};

/** A key that works on its own, without a modifier, as a global shortcut. */
const STANDALONE = /^(F([1-9]|1[0-9]|2[0-4])|PrintScreen)$/;

/** The key part of an accelerator for `code`, or null for a modifier or unknown key. */
export function keyName(code: string): string | null {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3);
  if (/^Digit[0-9]$/.test(code)) return code.slice(5);
  if (/^Numpad[0-9]$/.test(code)) return `Num${code.slice(6)}`;
  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(code)) return code;
  return NAMED[code] ?? null;
}

/**
 * The accelerator a key press makes, or null if it is not one yet (only modifiers held)
 * or not a usable global shortcut (a plain letter would swallow typing everywhere).
 */
export function fromEvent(event: KeyLike): string | null {
  const key = keyName(event.code);
  if (!key) return null;
  const modifiers = [
    event.ctrlKey && "Ctrl",
    event.altKey && "Alt",
    event.shiftKey && "Shift",
    event.metaKey && "Super",
  ].filter(Boolean) as string[];
  if (modifiers.length === 0 && !STANDALONE.test(key)) return null;
  if (modifiers.length === 1 && modifiers[0] === "Shift" && !STANDALONE.test(key)) return null;
  return [...modifiers, key].join("+");
}

/** "Alt+Shift+4" as the keys read: "Alt + Shift + 4"; Super as the Windows key. */
export function display(accelerator: string): string[] {
  return accelerator
    .split("+")
    .filter(Boolean)
    .map((part) => (part === "Super" ? "Win" : part === "PrintScreen" ? "Print Screen" : part));
}
