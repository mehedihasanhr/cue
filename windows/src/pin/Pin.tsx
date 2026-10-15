// A capture pinned above every window. Drag to move, scroll to resize, double-click or
// Esc to close; right-click for copy, opacity and close.

import { LogicalSize } from "@tauri-apps/api/dpi";
import { Menu } from "@tauri-apps/api/menu";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useState } from "react";
import { useShowWhenReady } from "../lib/hooks";
import { ipc, type HistoryItem } from "../lib/ipc";
import "./pin.css";

export default function Pin({ id }: { id: string }) {
  const [item, setItem] = useState<HistoryItem | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [opacity, setOpacity] = useState(1);
  const window = getCurrentWindow();

  useEffect(() => {
    ipc.historyItem(id).then(setItem).catch(() => window.destroy());
  }, [id]);
  useShowWhenReady(loaded);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") window.destroy();
      if (e.key.toLowerCase() === "c" && e.ctrlKey) ipc.historyCopy(id);
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [id]);

  async function onWheel(e: React.WheelEvent) {
    const size = (await window.innerSize()).toLogical(await window.scaleFactor());
    const factor = e.deltaY < 0 ? 1.08 : 1 / 1.08;
    const width = Math.max(60, size.width * factor);
    await window.setSize(new LogicalSize(width, (width * size.height) / size.width));
  }

  async function onContextMenu(e: React.MouseEvent) {
    e.preventDefault();
    const menu = await Menu.new({
      items: [
        { text: "Copy", action: () => ipc.historyCopy(id) },
        { text: "Edit", action: () => ipc.historyEdit(id) },
        { item: "Separator" },
        ...[100, 75, 50, 25].map((percent) => ({
          text: `Opacity ${percent}%`,
          checked: Math.round(opacity * 100) === percent,
          action: () => setOpacity(percent / 100),
        })),
        { item: "Separator" },
        { text: "Close", action: () => window.destroy() },
      ],
    });
    await menu.popup();
  }

  if (!item) return null;
  return (
    <div
      className="pin"
      onPointerDown={(e) => e.button === 0 && e.detail === 1 && window.startDragging()}
      onDoubleClick={() => window.destroy()}
      onWheel={onWheel}
      onContextMenu={onContextMenu}
      title="Drag to move · scroll to resize · double-click to close"
    >
      <img src={item.url} alt="" draggable={false} style={{ opacity }} onLoad={() => setLoaded(true)} />
    </div>
  );
}
