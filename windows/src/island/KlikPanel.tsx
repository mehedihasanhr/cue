// The Klik panel (Alt+Shift+K, the tray): the Mac's `FloatingPanelView` — a dark glass
// panel at the pointer with every capture in a grid. It goes away when you click
// elsewhere, as a panel does.

import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState } from "react";
import { useEvent } from "../lib/hooks";
import { ipc } from "../lib/ipc";
import { Panel } from "./Panel";
import "./island.css";

export default function KlikPanel() {
  const window = getCurrentWindow();
  const [columns, setColumns] = useState(4);
  const [toast, setToast] = useState<string | null>(null);

  const load = () => ipc.getSettings().then((s) => setColumns(s.panels.columns));
  useEffect(() => {
    document.documentElement.classList.add("island-root");
    load();
    window.show().then(() => window.setFocus());
    const off = window.onFocusChanged(({ payload: focused }) => {
      if (!focused) window.hide();
    });
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && window.hide();
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
          onStatus={(title) => {
            setToast(title);
            setTimeout(() => setToast(null), 1600);
          }}
        />
        {toast && <div className="toast" role="status">{toast}</div>}
      </div>
    </div>
  );
}
