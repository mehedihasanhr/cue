import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useRef, useState } from "react";
import { ipc } from "./ipc";

/** Runs `handler` whenever the Rust side emits `event`. */
export function useEvent<T>(event: string, handler: (payload: T) => void) {
  const saved = useRef(handler);
  saved.current = handler;
  useEffect(() => {
    const off = listen<T>(event, (e) => saved.current(e.payload));
    return () => {
      off.then((stop) => stop());
    };
  }, [event]);
}

/**
 * Shows the window once the page has something to draw, so it never flashes empty.
 * Not on an animation frame: a hidden window gets none, so it would never be shown.
 */
export function useShowWhenReady(ready: boolean) {
  useEffect(() => {
    if (!ready) return;
    const window = getCurrentWindow();
    window.show().then(() => window.setFocus());
  }, [ready]);
}

/** A short message at the bottom of the window. */
export function useToast(): [string | null, (text: string) => void] {
  const [text, setText] = useState<string | null>(null);
  const timer = useRef<number>(0);
  const show = (value: string) => {
    setText(value);
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setText(null), 2200);
  };
  useEvent<string>("toast", show);
  return [text, show];
}

/** Follows Settings › Appearance. */
export function useAppearance() {
  const apply = () =>
    ipc.getSettings().then((settings) => {
      const root = document.documentElement;
      if (settings.appearance === "system") root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", settings.appearance);
    });
  useEffect(() => {
    apply();
  }, []);
  useEvent("settings-changed", apply);
}
