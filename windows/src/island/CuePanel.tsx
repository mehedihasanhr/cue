// The Cue panel (Alt+Shift+K, the tray): the Mac's `FloatingPanelView` — a dark glass
// panel at the pointer with every capture in a grid. It goes away when you click
// elsewhere, as a panel does.

import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useRef, useState } from "react";
import { useEvent } from "../lib/hooks";
import { ipc } from "../lib/ipc";
import { Panel } from "./Panel";
import { PromptView, type Prompt } from "./Prompt";
import "./island.css";

export default function CuePanel() {
  const window = getCurrentWindow();
  const [columns, setColumns] = useState(4);
  const [toast, setToast] = useState<string | null>(null);
  const [prompt, setPrompt] = useState<Prompt | null>(null);
  // A menu or a form takes the focus for a moment; that is not a click elsewhere.
  const busy = useRef(false);

  const load = () => ipc.getSettings().then((s) => setColumns(s.panels.columns));
  useEffect(() => {
    document.documentElement.classList.add("island-root");
    load();
    window.show().then(() => window.setFocus());
    const off = window.onFocusChanged(({ payload: focused }) => {
      if (!focused && !busy.current) window.hide();
    });
    // Esc hides the panel once nothing inside it (a search, an open card, a form) wants it.
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && !e.defaultPrevented && !busy.current && window.hide();
    document.addEventListener("keydown", onKey);
    return () => {
      off.then((stop) => stop());
      document.removeEventListener("keydown", onKey);
    };
  }, []);
  useEvent("settings-changed", load);
  // Shown again (it is kept, not rebuilt): back to the top with the search cleared.
  useEvent("panel:shown", () => window.setFocus());

  return (
    <div className="floating-frame">
      <div className="floating-panel" style={{ ["--columns" as string]: columns }}>
        <div className="drag-strip" data-tauri-drag-region>
          <span />
        </div>
        <Panel
          mode="floating"
          onDone={() => window.hide()}
          onMenu={(open) => (busy.current = open)}
          onPrompt={(p) => {
            busy.current = true;
            setPrompt(p);
          }}
          onStatus={(title) => {
            setToast(title);
            setTimeout(() => setToast(null), 1600);
          }}
        />
        {toast && <div className="toast" role="status">{toast}</div>}
        {prompt && (
          <div className="floating-prompt" onMouseDown={(e) => e.target === e.currentTarget && setPrompt(null)}>
            <div className="floating-prompt-box">
              <PromptView
                prompt={prompt}
                onClose={() => {
                  setPrompt(null);
                  busy.current = false;
                  window.setFocus();
                }}
              />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
