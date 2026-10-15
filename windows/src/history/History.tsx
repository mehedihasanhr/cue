// History: every capture, newest first, grouped by day — the Windows counterpart of the
// Mac's Klik panel. Opened from the tray, Alt+Shift+K, or a second launch.

import { useEffect, useMemo, useState } from "react";
import { useAppearance, useEvent, useShowWhenReady, useToast } from "../lib/hooks";
import {
  AreaIcon, CopyIcon, FloatIcon, FolderIcon, LinkIcon, GearIcon, PencilIcon, PinIcon, RevealIcon, ScreenIcon, SearchIcon, TextIcon, TrashIcon, WindowIcon,
} from "../lib/icons";
import { ipc, message, type HistoryItem } from "../lib/ipc";
import "./history.css";

const title = (item: HistoryItem) => item.fileName.replace(/\.png$/i, "");

function dayLabel(date: Date): string {
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);
  if (date.toDateString() === today.toDateString()) return "Today";
  if (date.toDateString() === yesterday.toDateString()) return "Yesterday";
  return date.toLocaleDateString(undefined, {
    weekday: "long", month: "long", day: "numeric",
    year: date.getFullYear() === today.getFullYear() ? undefined : "numeric",
  });
}

export default function History() {
  useAppearance();
  const [items, setItems] = useState<HistoryItem[] | null>(null);
  const [query, setQuery] = useState("");
  const [renaming, setRenaming] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const [toast, showToast] = useToast();

  const load = () => ipc.historyItems().then(setItems).then(() => setVersion((v) => v + 1));
  useEffect(() => {
    load();
  }, []);
  useEvent("library-changed", load);
  useShowWhenReady(items !== null);

  const groups = useMemo(() => {
    const filtered = (items ?? []).filter((item) => title(item).toLowerCase().includes(query.trim().toLowerCase()));
    const pinned = filtered.filter((item) => item.pinned);
    const rest = filtered.filter((item) => !item.pinned);
    const byDay = new Map<string, HistoryItem[]>();
    for (const item of rest) {
      const label = dayLabel(new Date(item.createdAt));
      byDay.set(label, [...(byDay.get(label) ?? []), item]);
    }
    return [...(pinned.length ? [["Pinned", pinned] as const] : []), ...byDay.entries()];
  }, [items, query]);

  const act = (work: Promise<unknown>, done?: string) =>
    work.then(() => done && showToast(done)).catch((error) => showToast(message(error)));

  return (
    <div className="history">
      <header className="history-bar">
        <div className="capture-buttons" role="toolbar" aria-label="Capture">
          <button className="button primary" onClick={() => ipc.startCapture("area")}><AreaIcon /> Area</button>
          <button className="button" onClick={() => ipc.startCapture("window")}><WindowIcon /> Window</button>
          <button className="button" onClick={() => ipc.startCapture("fullScreen")}><ScreenIcon /> Full Screen</button>
          <button className="button" onClick={() => ipc.startCapture("text")}><TextIcon /> Text</button>
        </div>
        <div className="history-tools">
          <label className="search">
            <SearchIcon />
            <input placeholder="Search" value={query} onChange={(e) => setQuery(e.target.value)} aria-label="Search captures" />
          </label>
          <button className="button icon" title="Open the captures folder" onClick={() => act(ipc.historyOpenFolder())}><FolderIcon /></button>
          <button className="button icon" title="Settings" onClick={() => ipc.runAction("showSettings")}><GearIcon /></button>
        </div>
      </header>

      <main className="history-list">
        {items && items.length === 0 && (
          <div className="empty">
            <AreaIcon size={40} />
            <h2>No captures yet</h2>
            <p>Press <kbd>Alt</kbd> <kbd>Shift</kbd> <kbd>4</kbd> to capture an area. Every capture is kept here.</p>
          </div>
        )}
        {groups.map(([label, group]) => (
          <section key={label}>
            <h3>{label}</h3>
            <div className="grid">
              {group.map((item) => (
                <Card
                  key={item.id}
                  item={item}
                  version={version}
                  renaming={renaming === item.id}
                  onRename={() => setRenaming(item.id)}
                  onRenamed={(name) => {
                    setRenaming(null);
                    if (name && name !== title(item)) act(ipc.historyRename(item.id, name));
                  }}
                  onEdit={() => act(ipc.historyEdit(item.id))}
                  onCopy={() => act(ipc.historyCopy(item.id), "Copied")}
                  onReveal={() => act(ipc.historyReveal(item.id))}
                  onPin={() => act(ipc.historySetPinned(item.id, !item.pinned))}
                  onFloat={() => act(ipc.historyFloat(item.id))}
                  onShare={() => {
                    showToast("Uploading…");
                    act(ipc.historyShare(item.id), "Link copied");
                  }}
                  onDelete={() => act(ipc.historyDelete(item.id), "Moved to the Recycle Bin")}
                />
              ))}
            </div>
          </section>
        ))}
      </main>
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  );
}

type CardProps = {
  item: HistoryItem;
  version: number;
  renaming: boolean;
  onRename: () => void;
  onRenamed: (name: string | null) => void;
  onEdit: () => void;
  onCopy: () => void;
  onReveal: () => void;
  onPin: () => void;
  onFloat: () => void;
  onShare: () => void;
  onDelete: () => void;
};

function Card({ item, version, renaming, onRename, onRenamed, onEdit, onCopy, onReveal, onPin, onFloat, onShare, onDelete }: CardProps) {
  const time = new Date(item.createdAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return (
    <article
      className="card"
      tabIndex={0}
      onDoubleClick={onEdit}
      onKeyDown={(e) => {
        if (renaming) return;
        if (e.key === "Enter") onEdit();
        if (e.key === "Delete") onDelete();
        if (e.key === "F2") onRename();
        if (e.key.toLowerCase() === "c" && e.ctrlKey) onCopy();
      }}
      aria-label={title(item)}
    >
      <div className="thumb">
        <img src={`${item.thumbnailUrl}?v=${version}`} alt="" draggable={false} loading="lazy" />
        <div className="card-actions">
          <button className="chip" title="Edit (Enter)" onClick={onEdit}><PencilIcon /></button>
          <button className="chip" title="Copy (Ctrl+C)" onClick={onCopy}><CopyIcon /></button>
          <button className="chip" title="Copy share link" onClick={onShare}><LinkIcon /></button>
          <button className="chip" title="Float on screen" onClick={onFloat}><FloatIcon /></button>
          <button className="chip" title="Show in Explorer" onClick={onReveal}><RevealIcon /></button>
          <button className={`chip ${item.pinned ? "on" : ""}`} title={item.pinned ? "Unpin" : "Pin to top"} onClick={onPin}><PinIcon /></button>
          <button className="chip danger" title="Delete (Del)" onClick={onDelete}><TrashIcon /></button>
        </div>
      </div>
      {renaming ? (
        <input
          className="rename"
          autoFocus
          defaultValue={title(item)}
          onFocus={(e) => e.target.select()}
          onBlur={(e) => onRenamed(e.target.value.trim())}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
            if (e.key === "Escape") onRenamed(null);
          }}
        />
      ) : (
        <div className="name" title="Double-click to rename (F2)" onDoubleClick={(e) => { e.stopPropagation(); onRename(); }}>
          {title(item)}
        </div>
      )}
      <div className="meta">{time} · {item.pixelWidth} × {item.pixelHeight}</div>
    </article>
  );
}
