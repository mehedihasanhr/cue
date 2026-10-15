// What the island shows open, and what the Klik panel shows: the Mac's `IslandPanel`
// and `FloatingPanelView`. A search field and the capture tools on top, the tabs, then
// the captures as cards — in a horizontal strip grouped by day on the island, in a grid
// on the panel.

import { Menu } from "@tauri-apps/api/menu";
import { useEffect, useMemo, useRef, useState } from "react";
import { useEvent } from "../lib/hooks";
import { ipc, message, type HistoryItem } from "../lib/ipc";
import { Icon, STROKE, type IconName } from "../ui/icon";

export type PanelMode = "island" | "floating";

type Tab = "all" | "captures";
const TABS: { id: Tab; title: string }[] = [
  { id: "all", title: "All" },
  { id: "captures", title: "Captures" },
];

export const CARD = { width: 156, height: 124, gap: 10, header: 24 };

type Props = {
  mode: PanelMode;
  /** The island takes the keyboard when the search field is clicked. */
  onWantsKeyboard?: () => void;
  /** A menu is open: the island must not close under it. */
  onMenu?: (open: boolean) => void;
  onStatus?: (title: string, symbol: IconName, subtitle?: string) => void;
  /** Something was chosen that leaves the panel (a capture, the editor). */
  onDone?: () => void;
  initialTab?: string;
};

const title = (item: HistoryItem) => item.fileName.replace(/\.png$/i, "");
const isDefaultName = (item: HistoryItem) => /^Screenshot \d{4}-\d{2}-\d{2} at /.test(title(item));

function dayTitle(date: Date): string {
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);
  if (date.toDateString() === today.toDateString()) return "Today";
  if (date.toDateString() === yesterday.toDateString()) return "Yesterday";
  return date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

export function Panel({ mode, onWantsKeyboard, onMenu, onStatus, onDone, initialTab }: Props) {
  const [items, setItems] = useState<HistoryItem[]>([]);
  const [tab, setTab] = useState<Tab>(initialTab === "captures" ? "captures" : "all");
  const [search, setSearch] = useState("");
  const [renaming, setRenaming] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const searchField = useRef<HTMLInputElement>(null);

  const load = () => ipc.historyItems().then((list) => {
    setItems(list);
    setVersion((v) => v + 1);
  });
  useEffect(() => {
    load();
  }, []);
  useEvent("library-changed", load);

  const query = search.trim().toLowerCase();
  const searching = query.length > 0;
  const shown = useMemo(() => {
    const matching = searching ? items.filter((i) => title(i).toLowerCase().includes(query)) : items;
    // Pinned first, as the Mac's strip does.
    return [...matching.filter((i) => i.pinned), ...matching.filter((i) => !i.pinned)];
  }, [items, query]);

  const act = (work: Promise<unknown>, done?: [string, IconName]) =>
    work.then(() => done && onStatus?.(done[0], done[1])).catch((e) => onStatus?.("Couldn't do that", "exclamationmark.triangle.fill", message(e)));

  const actions = {
    copy: (i: HistoryItem) => act(ipc.historyCopy(i.id), ["Copied to clipboard", "checkmark.circle.fill"]),
    edit: (i: HistoryItem) => {
      act(ipc.historyEdit(i.id));
      onDone?.();
    },
    pin: (i: HistoryItem) => act(ipc.historySetPinned(i.id, !i.pinned)),
    remove: (i: HistoryItem) => act(ipc.historyDelete(i.id), ["Moved to the Recycle Bin", "trash"]),
    reveal: (i: HistoryItem) => act(ipc.historyReveal(i.id)),
    float: (i: HistoryItem) => act(ipc.historyFloat(i.id)),
    share: (i: HistoryItem) => {
      onStatus?.("Uploading…", "arrow.up");
      act(ipc.historyShare(i.id), ["Link copied", "link"]);
    },
  };

  async function cardMenu(event: React.MouseEvent, item: HistoryItem) {
    event.preventDefault();
    const menu = await Menu.new({
      items: [
        { text: "Edit", action: () => actions.edit(item) },
        { text: "Copy to Clipboard", action: () => actions.copy(item) },
        { text: "Show in Explorer", action: () => actions.reveal(item) },
        { text: "Pin to Screen", action: () => actions.float(item) },
        { text: "Copy Share Link", action: () => actions.share(item) },
        { item: "Separator" },
        { text: item.pinned ? "Unpin" : "Pin", action: () => actions.pin(item) },
        { text: "Rename…", action: () => setRenaming(item.id) },
        { item: "Separator" },
        { text: "Delete", action: () => actions.remove(item) },
      ],
    });
    onMenu?.(true);
    await menu.popup();
    onMenu?.(false);
  }

  async function moreTools() {
    const menu = await Menu.new({
      items: [
        { text: "Capture Window", action: () => capture("window") },
        { text: "Capture Text", action: () => capture("text") },
        { item: "Separator" },
        { text: "Settings…", action: () => { ipc.runAction("showSettings"); onDone?.(); } },
      ],
    });
    onMenu?.(true);
    await menu.popup();
    onMenu?.(false);
  }

  function capture(mode: "area" | "fullScreen" | "window" | "text") {
    onDone?.();
    // A moment for the island or panel to get out of the picture.
    setTimeout(() => ipc.startCapture(mode), mode === "fullScreen" ? 220 : 60);
  }

  const card = (item: HistoryItem, size?: { width: number | string; height: number }) => (
    <CaptureCard
      key={item.id}
      item={item}
      version={version}
      size={size}
      floating={mode === "floating"}
      renaming={renaming === item.id}
      onRenamed={(name) => {
        setRenaming(null);
        if (name && name !== title(item)) act(ipc.historyRename(item.id, name));
      }}
      onTap={() => actions.edit(item)}
      onMenu={(e) => cardMenu(e, item)}
      actions={actions}
    />
  );

  const header =
    mode === "island" ? (
      <div className="panel-header">
        <label className={`search ${searching ? "on" : ""}`} onMouseDown={() => onWantsKeyboard?.()}>
          <Icon name="magnifyingglass" size={14} weight={STROKE.medium} />
          <input
            ref={searchField}
            value={search}
            placeholder="Search everything"
            spellCheck={false}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape" && search) {
                e.stopPropagation();
                setSearch("");
              }
            }}
            aria-label="Search"
          />
          {searching && (
            <>
              <span className="matches">{shown.length ? `${shown.length} ${shown.length === 1 ? "match" : "matches"}` : "No matches"}</span>
              <button className="clear" title="Clear the search" onClick={() => setSearch("")}>
                <Icon name="xmark.circle.fill" size={15} />
              </button>
            </>
          )}
        </label>
        {!searching && (
          <div className="capture-bar">
            <HoverButton symbol="viewfinder" help="Capture area" onClick={() => capture("area")} />
            <HoverButton symbol="display" help="Capture full screen" onClick={() => capture("fullScreen")} />
            <HoverButton symbol="ellipsis" help="More tools" onClick={moreTools} />
          </div>
        )}
      </div>
    ) : (
      <div className="panel-header floating">
        <label className={`search capsule ${searching ? "on" : ""}`}>
          <Icon name="magnifyingglass" size={14} weight={STROKE.medium} />
          <input
            autoFocus
            value={search}
            placeholder="Search everything"
            spellCheck={false}
            onChange={(e) => setSearch(e.target.value)}
            aria-label="Search"
          />
          {searching && (
            <button className="clear" title="Clear the search" onClick={() => setSearch("")}>
              <Icon name="xmark.circle.fill" size={14} />
            </button>
          )}
        </label>
        <div className="tool-group">
          <ToolButton symbol="display" help="Capture full screen" onClick={() => capture("fullScreen")} />
          <ToolButton symbol="viewfinder" help="Capture area" onClick={() => capture("area")} />
          <ToolButton symbol="macwindow" help="Capture window" onClick={() => capture("window")} />
          <ToolButton symbol="text.viewfinder" help="Capture text" onClick={() => capture("text")} />
        </div>
        <div className="tool-group">
          <ToolButton symbol="gearshape" help="Settings" onClick={() => { ipc.runAction("showSettings"); onDone?.(); }} />
        </div>
      </div>
    );

  const empty = (
    <div className="panel-empty">
      <Icon name="photo.on.rectangle" size={32} />
      <div className="empty-title">{searching ? "Nothing matches" : "No captures yet"}</div>
      {!searching && (
        <button className="empty-action" onClick={() => capture("area")}>
          Capture an area <span className="keys">Alt + Shift + 4</span>
        </button>
      )}
    </div>
  );

  return (
    <div className={`panel ${mode}`}>
      {header}
      {mode === "island" && !searching && (
        <div className="tab-row" role="tablist">
          {TABS.map((t) => (
            <button
              key={t.id}
              role="tab"
              aria-selected={tab === t.id}
              className={`tab-pill ${tab === t.id ? "on" : ""}`}
              onClick={() => setTab(t.id)}
            >
              {t.title}
              {items.length > 0 && <span className="count">{items.length}</span>}
            </button>
          ))}
        </div>
      )}
      {shown.length === 0 ? empty : mode === "island" ? <DayStrip items={shown} card={card} /> : <DayGrid items={shown} card={card} />}
    </div>
  );
}

// MARK: - The island's strip

function groupByDay(items: HistoryItem[]): { title: string; items: HistoryItem[] }[] {
  const groups: { title: string; items: HistoryItem[] }[] = [];
  for (const item of items) {
    const name = item.pinned ? "Pinned" : dayTitle(new Date(item.createdAt));
    const last = groups[groups.length - 1];
    if (last && last.title === name) last.items.push(item);
    else groups.push({ title: name, items: [item] });
  }
  return groups;
}

/** Cards in one row, grouped by day under small headers; scrolls sideways by wheel or drag. */
function DayStrip({ items, card }: { items: HistoryItem[]; card: (i: HistoryItem) => React.ReactNode }) {
  const row = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ start: false, end: false });
  const drag = useRef<{ x: number; left: number; moved: boolean } | null>(null);

  const measure = () => {
    const el = row.current;
    if (!el) return;
    setEdges({ start: el.scrollLeft > 0, end: el.scrollLeft < el.scrollWidth - el.clientWidth - 1 });
  };
  useEffect(measure, [items]);

  return (
    <div className="strip-frame">
      <div
        ref={row}
        className="strip"
        onScroll={measure}
        onWheel={(e) => {
          // A mouse wheel scrolls the row, as a trackpad's sideways swipe does.
          if (Math.abs(e.deltaY) > Math.abs(e.deltaX) && row.current) row.current.scrollLeft += e.deltaY;
        }}
        onPointerDown={(e) => {
          if (e.button === 0) drag.current = { x: e.clientX, left: row.current!.scrollLeft, moved: false };
        }}
        onPointerMove={(e) => {
          const d = drag.current;
          if (!d || !row.current) return;
          if (Math.abs(e.clientX - d.x) > 3) d.moved = true;
          if (d.moved) row.current.scrollLeft = d.left - (e.clientX - d.x);
        }}
        onPointerUp={() => setTimeout(() => (drag.current = null))}
        onClickCapture={(e) => {
          // The click that ends a drag is not a click on a card.
          if (drag.current?.moved) e.stopPropagation();
        }}
      >
        {groupByDay(items).map((group) => (
          <section key={group.title + group.items[0].id} className="strip-group">
            <h3>{group.title}</h3>
            <div className="strip-cards">{group.items.map((i) => card(i))}</div>
          </section>
        ))}
      </div>
      <div className={`fade start ${edges.start ? "on" : ""}`} />
      <div className={`fade end ${edges.end ? "on" : ""}`} />
    </div>
  );
}

/** The panel's grid: the same groups, as rows of equal columns. */
function DayGrid({ items, card }: { items: HistoryItem[]; card: (i: HistoryItem, size: { width: string; height: number }) => React.ReactNode }) {
  return (
    <div className="grid-scroll">
      {groupByDay(items).map((group) => (
        <section key={group.title + group.items[0].id}>
          <h3>{group.title}</h3>
          <div className="grid">{group.items.map((i) => card(i, { width: "100%", height: 150 }))}</div>
        </section>
      ))}
    </div>
  );
}

// MARK: - Cards

type Actions = Record<"copy" | "edit" | "pin" | "remove", (i: HistoryItem) => void>;

function CaptureCard(props: {
  item: HistoryItem;
  version: number;
  size?: { width: number | string; height: number };
  floating: boolean;
  renaming: boolean;
  onRenamed: (name: string | null) => void;
  onTap: () => void;
  onMenu: (e: React.MouseEvent) => void;
  actions: Actions;
}) {
  const { item, actions } = props;
  const [copied, setCopied] = useState(false);
  const time = new Date(item.createdAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  return (
    <div
      className={`card ${props.floating ? "quick" : ""}`}
      style={props.size ? { width: props.size.width, height: props.size.height } : undefined}
      onClick={props.onTap}
      onContextMenu={props.onMenu}
      title={title(item)}
    >
      <img src={`${item.thumbnailUrl}?v=${props.version}`} alt="" draggable={false} loading="lazy" />
      <div className="caption">
        {props.renaming ? (
          <input
            className="rename"
            autoFocus
            defaultValue={title(item)}
            onClick={(e) => e.stopPropagation()}
            onFocus={(e) => e.target.select()}
            onBlur={(e) => props.onRenamed(e.target.value.trim())}
            onKeyDown={(e) => {
              e.stopPropagation();
              if (e.key === "Enter") (e.target as HTMLInputElement).blur();
              if (e.key === "Escape") props.onRenamed(null);
            }}
          />
        ) : (
          !isDefaultName(item) && <div className="caption-title">{title(item)}</div>
        )}
        <div className="caption-line">
          <span>{time}</span>
          <span className="spacer" />
          {item.pinned && <span className="pinned"><Icon name="pin.fill" size={11} /></span>}
          <span className="badge">{item.pixelWidth} × {item.pixelHeight}</span>
        </div>
      </div>
      <div className="card-actions" onClick={(e) => e.stopPropagation()}>
        <CardAction
          symbol={copied ? "checkmark" : "doc.on.doc"}
          help="Copy to clipboard"
          tint={copied ? "#30d158" : undefined}
          onClick={() => {
            actions.copy(item);
            setCopied(true);
            setTimeout(() => setCopied(false), 1200);
          }}
        />
        <CardAction symbol="pencil" help="Edit" onClick={() => actions.edit(item)} />
        <CardAction symbol={item.pinned ? "pin.slash.fill" : "pin"} help={item.pinned ? "Unpin" : "Pin"} onClick={() => actions.pin(item)} />
        <CardAction symbol="trash" help="Remove" tint="#ff453a" onClick={() => actions.remove(item)} />
      </div>
    </div>
  );
}

function CardAction({ symbol, help, tint, onClick }: { symbol: IconName; help: string; tint?: string; onClick: () => void }) {
  return (
    <button className="card-action" title={help} aria-label={help} style={tint ? { color: tint } : undefined} onClick={onClick}>
      <Icon name={symbol} size={13} weight={STROKE.bold} />
    </button>
  );
}

function HoverButton({ symbol, help, onClick }: { symbol: IconName; help: string; onClick: () => void }) {
  return (
    <button className="hover-button" title={help} aria-label={help} onClick={onClick}>
      <Icon name={symbol} size={15} weight={STROKE.medium} />
    </button>
  );
}

function ToolButton({ symbol, help, onClick }: { symbol: IconName; help: string; onClick: () => void }) {
  return (
    <button className="tool-button" title={help} aria-label={help} onClick={onClick}>
      <Icon name={symbol} size={14} weight={STROKE.medium} />
    </button>
  );
}
