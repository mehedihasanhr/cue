// Every recording, newest first — the Mac's library window. A card opens its editor;
// its menu shows it in Explorer or puts it in the Recycle Bin.

import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useMemo, useState } from "react";
import { popup } from "../../../src/island/menus";
import { Icon } from "../../../src/ui/icon";
import { clockText, fileUrl, studio, type LibraryItem } from "../lib/ipc";
import "./library.css";

export default function Library() {
  const [items, setItems] = useState<LibraryItem[] | null>(null);
  const [search, setSearch] = useState("");
  const load = () => studio.library().then(setItems);
  useEffect(() => {
    load().then(() => getCurrentWindow().show());
    const off = listen("library-changed", load);
    return () => {
      off.then((stop) => stop());
    };
  }, []);

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (items ?? []).filter((i) => !q || i.name.toLowerCase().includes(q));
  }, [items, search]);

  if (!items) return null;
  return (
    <div className="library">
      <header className="library-header">
        <h1>Recordings</h1>
        <label className="library-search">
          <Icon name="magnifyingglass" size={14} />
          <input value={search} placeholder="Search" onChange={(e) => setSearch(e.target.value)} spellCheck={false} />
        </label>
        <button className="new-recording" onClick={() => studio.showBar()}>
          <span className="dot" /> New Recording
        </button>
      </header>
      {shown.length === 0 ? (
        <div className="library-empty">
          <Icon name="film" size={40} weight={1.2} />
          <div className="empty-title">{items.length ? "Nothing matches" : "No recordings yet"}</div>
          {!items.length && <div className="empty-sub">Record your screen, then make it look edited — zooms that follow the pointer, a background, a smooth cursor.</div>}
        </div>
      ) : (
        <div className="library-grid">
          {shown.map((item) => (
            <button
              key={item.path}
              className="recording-card"
              onClick={() => studio.openEditor(item.path)}
              onContextMenu={(e) => {
                e.preventDefault();
                popup([
                  { text: "Open", action: () => studio.openEditor(item.path) },
                  { text: "Show in Explorer", action: () => studio.reveal(item.path) },
                  "-",
                  { text: "Move to Recycle Bin", action: () => studio.remove(item.path) },
                ]);
              }}
            >
              <div className="poster">
                <video src={`${fileUrl(item.path, "media/screen.mp4")}#t=0.5`} preload="metadata" muted />
                <span className="duration">{clockText(item.duration)}</span>
                {item.unfinished && <span className="badge warn">Unfinished</span>}
                {item.edited && <span className="badge">Edited</span>}
              </div>
              <div className="card-name">{item.name}</div>
              <div className="card-meta">
                {new Date(item.createdAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
                {item.width > 0 && ` · ${item.width} × ${item.height}`}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
