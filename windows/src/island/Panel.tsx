// What the island shows open, and what the Klik panel shows — the Mac's `IslandPanel`:
// search and the capture buttons on top, the tabs (All, Assets, Tasks, Notes, Captures,
// Colors, Snippets, Clipboard), then the tab's items as cards in a strip grouped by day,
// with Recent, Pinned and the groups under it. Searching looks through everything and
// answers what it can work out on the spot. A card opens in place; ← → move between.

import { forwardRef, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ipc, message, type HistoryItem } from "../lib/ipc";
import { Icon, STROKE, type IconName } from "../ui/icon";
import { answers as quickAnswers, type QuickAnswer } from "./answers";
import {
  AnswerCardBody,
  AssetCardBody,
  assetCaption,
  CardAction,
  CardFrame,
  CaptureCardBody,
  captureCaption,
  captureTitle,
  ClipCardBody,
  clipCaption,
  ColorCardBody,
  colorCaption,
  CopyAction,
  NoteCardBody,
  noteCaption,
  SnippetCardBody,
  snippetCaption,
  TaskCardBody,
  nextStatusTitle,
} from "./cards";
import { format, FORMAT_TITLES, FORMATS, type ColorFormat } from "./colormath";
import {
  dayTitle,
  firstLine,
  island,
  NEXT_STATUS,
  PRIORITY_ORDER,
  PRIORITY_TITLES,
  STATUS_ORDER,
  STATUS_TITLES,
  store,
  useCaptures,
  useCollection,
  useNotes,
  type Asset,
  type ClipItem,
  type ColorItem,
  type Group,
  type GroupKind,
  type Note,
  type Snippet,
  type TaskItem,
} from "./data";
import { Detail, type DetailButton, type DetailItem } from "./Detail";
import { popup, type MenuEntry } from "./menus";
import type { Prompt } from "./Prompt";
import { TasksView } from "./Tasks";
import { applicable, apply, extract, TRANSFORM_TITLES } from "./transforms";

export type PanelMode = "island" | "floating";

export type Tab = "all" | "assets" | "tasks" | "notes" | "captures" | "colors" | "snippets" | "clipboard";
export const TABS: { id: Tab; title: string; symbol: IconName }[] = [
  { id: "all", title: "All", symbol: "square.grid.2x2" },
  { id: "assets", title: "Assets", symbol: "tray.full" },
  { id: "tasks", title: "Tasks", symbol: "checklist" },
  { id: "notes", title: "Notes", symbol: "note.text" },
  { id: "captures", title: "Captures", symbol: "photo.on.rectangle" },
  { id: "colors", title: "Colors", symbol: "paintpalette" },
  { id: "snippets", title: "Snippets", symbol: "text.badge.plus" },
  { id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard" },
];
const GROUPED: Tab[] = ["all", "captures", "clipboard", "colors", "assets"];

/** Recent, Pinned, or a group's id. */
type Filter = "recent" | "pinned" | string;

type Entry =
  | { kind: "captures"; item: HistoryItem }
  | { kind: "clipboard"; item: ClipItem }
  | { kind: "assets"; item: Asset }
  | { kind: "colors"; item: ColorItem }
  | { kind: "snippets"; item: Snippet }
  | { kind: "notes"; item: Note }
  | { kind: "tasks"; item: TaskItem }
  | { kind: "answers"; item: QuickAnswer };

const keyOf = (e: Entry) => `${e.kind}:${e.item.id}`;
const dateOf = (e: Entry) => (e.kind === "notes" ? e.item.updatedAt : e.kind === "answers" ? "" : e.item.createdAt);
const pinnedOf = (e: Entry) => "pinned" in e.item && !!e.item.pinned;
const groupOf = (e: Entry) => ("groupID" in e.item ? (e.item.groupID ?? undefined) : undefined);

type Props = {
  mode: PanelMode;
  /** The island takes the keyboard when the search field (or a form) is clicked. */
  onWantsKeyboard?: () => void;
  /** A menu is open: the island must not close under it. */
  onMenu?: (open: boolean) => void;
  /** Something to say after the panel has closed. */
  onStatus?: (title: string, symbol: IconName, subtitle?: string) => void;
  /** Something was chosen that leaves the panel (a capture, the editor). */
  onDone?: () => void;
  /** A form to fill in (rename, a new note…), shown in the island's compact form. */
  onPrompt?: (prompt: Prompt) => void;
  initialTab?: string;
  /** Files are being dragged over the island. */
  dropping?: boolean;
};

const read = (key: string) => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};
const write = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* a convenience */
  }
};

export function Panel({ mode, onWantsKeyboard, onMenu, onStatus, onDone, onPrompt, initialTab, dropping }: Props) {
  const { items: captures, version } = useCaptures();
  const clipboard = useCollection("clipboard");
  const assets = useCollection("assets");
  const colors = useCollection("colors");
  const snippets = useCollection("snippets");
  const tasks = useCollection("tasks");
  const projects = useCollection("projects");
  const groups = useCollection("groups");
  const notes = useNotes();

  const [tab, setTabState] = useState<Tab>(() => {
    const wanted = (initialTab || read("island.tab") || "all") as Tab;
    return TABS.some((t) => t.id === wanted) ? wanted : "all";
  });
  const [filters, setFilters] = useState<Record<string, Filter>>({});
  const [search, setSearch] = useState(() => {
    // Debug builds' `--island-demo expanded:search=<text>`.
    const demo = read("island.demo.search");
    if (demo) write("island.demo.search", "");
    return demo ?? "";
  });
  const [searchTab, setSearchTab] = useState<Tab | "answers" | null>(null);
  const [detailKey, setDetailKey] = useState<string | null>(null);
  const [copiedKey, setCopiedKey] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [colorFormat, setColorFormatState] = useState<ColorFormat>(() => (FORMATS.includes(read("colors.format") as ColorFormat) ? (read("colors.format") as ColorFormat) : "hex"));
  const searchField = useRef<HTMLInputElement>(null);
  const toastTimer = useRef(0);

  const setTab = (t: Tab) => {
    setTabState(t);
    setDetailKey(null);
    write("island.tab", t);
  };
  const filter: Filter = filters[tab] ?? "recent";
  const setFilter = (f: Filter) => setFilters((all) => ({ ...all, [tab]: f }));
  const setColorFormat = (f: ColorFormat) => {
    setColorFormatState(f);
    write("colors.format", f);
  };

  const say = (text: string) => {
    setToast(text);
    window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 1600);
  };
  const flashCopied = (key: string) => {
    setCopiedKey(key);
    setTimeout(() => setCopiedKey((k) => (k === key ? null : k)), 900);
  };
  const fail = (e: unknown) => say(`Couldn't do that: ${message(e)}`);
  const run = (work: Promise<unknown>, done?: string) => work.then(() => done && say(done)).catch(fail);

  // MARK: Entries

  const entriesFor = (t: Tab): Entry[] => {
    switch (t) {
      case "captures": return captures.map((item) => ({ kind: "captures", item }));
      case "clipboard": return clipboard.map((item) => ({ kind: "clipboard", item }));
      case "assets": return assets.map((item) => ({ kind: "assets", item }));
      case "colors": return colors.map((item) => ({ kind: "colors", item }));
      case "snippets": return snippets.map((item) => ({ kind: "snippets", item }));
      case "notes": return notes.map((item) => ({ kind: "notes", item }));
      case "tasks": return tasks.map((item) => ({ kind: "tasks", item }));
      case "all":
        return (["captures", "clipboard", "assets", "colors", "snippets", "notes"] as Tab[])
          .flatMap(entriesFor)
          .sort((a, b) => dateOf(b).localeCompare(dateOf(a)));
    }
  };

  const applyFilter = (list: Entry[], f: Filter, t: Tab): Entry[] => {
    if (!GROUPED.includes(t)) return list;
    if (f === "recent") return list.filter((e) => e.kind === "snippets" || e.kind === "notes" || (!pinnedOf(e) && !groupOf(e)));
    if (f === "pinned") return list.filter(pinnedOf);
    const inGroup = list.filter((e) => groupOf(e) === f);
    return [...inGroup.filter(pinnedOf), ...inGroup.filter((e) => !pinnedOf(e))];
  };

  const count = (t: Tab) => {
    if (t === "tasks") return tasks.filter((x) => x.status !== "complete").length;
    if (t === "snippets") return snippets.length;
    if (t === "notes") return notes.length;
    return applyFilter(entriesFor(t), filters[t] ?? "recent", t).length;
  };

  // MARK: Search

  const query = search.trim().toLowerCase();
  const searching = query.length > 0;
  const words = query.split(/\s+/).filter(Boolean);
  const matches = (fields: (string | undefined)[]) => {
    const haystack = fields.filter(Boolean).join("\n").toLowerCase();
    return words.every((w) => haystack.includes(w));
  };
  const projectName = (id?: string) => projects.find((p) => p.id === id)?.name;
  const results = useMemo(() => {
    if (!searching) return null;
    const found: { tab: Tab; entries: Entry[] }[] = [
      { tab: "captures", entries: captures.filter((c) => matches([captureTitle(c), `${c.pixelWidth} × ${c.pixelHeight}`, `${c.pixelWidth}x${c.pixelHeight}`])).map((item) => ({ kind: "captures", item })) },
      { tab: "clipboard", entries: clipboard.filter((c) => matches([c.text, c.name, c.sourceName, c.kind])).map((item) => ({ kind: "clipboard", item })) },
      { tab: "assets", entries: assets.filter((a) => matches([a.fileName])).map((item) => ({ kind: "assets", item })) },
      { tab: "colors", entries: colors.filter((c) => matches([c.name, ...FORMATS.map((f) => format(c.color, f))])).map((item) => ({ kind: "colors", item })) },
      { tab: "tasks", entries: tasks.filter((t) => matches([t.text, projectName(t.projectID), STATUS_TITLES[t.status], PRIORITY_TITLES[t.priority]])).map((item) => ({ kind: "tasks", item })) },
      { tab: "snippets", entries: snippets.filter((s) => matches([s.keyword, s.name, s.text])).map((item) => ({ kind: "snippets", item })) },
      { tab: "notes", entries: notes.filter((n) => matches([firstLine(n.text), n.text])).map((item) => ({ kind: "notes", item })) },
    ];
    return found.filter((g) => g.entries.length > 0);
  }, [searching, query, captures, clipboard, assets, colors, tasks, snippets, notes, projects]);
  const answers = useMemo(() => (searching ? quickAnswers(search) : []), [search]);
  const resultCount = (results?.reduce((n, g) => n + g.entries.length, 0) ?? 0) + answers.length;

  // MARK: Actions

  const copy = (e: Entry) => {
    const key = keyOf(e);
    const done = () => flashCopied(key);
    switch (e.kind) {
      case "captures": return ipc.historyCopy(e.item.id).then(done, fail);
      case "clipboard": return island.clipCopy(e.item.id).then(done, fail);
      case "assets": return island.assetCopy(e.item.id).then(done, fail);
      case "colors": return island.copyText(format(e.item.color, colorFormat)).then(done, fail);
      case "snippets":
        store.update("snippets", e.item.id, { uses: (e.item.uses ?? 0) + 1 });
        return island.copyText(expand(e.item.text)).then(done, fail);
      case "notes": return island.copyText(e.item.text).then(done, fail);
      case "tasks": return island.copyText(e.item.text).then(done, fail);
      case "answers": return island.copyText(e.item.value).then(done, fail);
    }
  };

  /** Pastes into the app in front: the panel gets out of the way first. */
  const pasteWith = (work: () => Promise<boolean>) => {
    onDone?.();
    setTimeout(() => {
      work()
        .then((pasted) => !pasted && onStatus?.("Copied — press Ctrl+V to paste", "doc.on.clipboard"))
        .catch((e) => onStatus?.("Couldn't paste", "exclamationmark.triangle.fill", message(e)));
    }, 140);
  };
  const paste = (e: Entry) => {
    switch (e.kind) {
      case "captures": return pasteWith(() => island.paste("captures", e.item.id));
      case "clipboard": return pasteWith(() => island.paste("clipboard", e.item.id));
      case "assets": return pasteWith(() => island.paste("assets", e.item.id));
      case "colors": return pasteWith(() => island.copyText(format(e.item.color, colorFormat), true));
      case "snippets":
        store.update("snippets", e.item.id, { uses: (e.item.uses ?? 0) + 1 });
        return pasteWith(() => island.copyText(expand(e.item.text), true));
      case "notes": return pasteWith(() => island.copyText(e.item.text, true));
      case "answers": return pasteWith(() => island.copyText(e.item.value, true));
      default: return;
    }
  };

  const togglePin = (e: Entry) => {
    switch (e.kind) {
      case "captures": return run(ipc.historySetPinned(e.item.id, !e.item.pinned));
      case "clipboard": case "assets": case "colors": return run(store.update(e.kind, e.item.id, { pinned: !e.item.pinned }));
    }
  };

  const setGroup = (e: Entry, group: string | null) => {
    if (e.kind === "captures") return run(island.captureGroup(e.item.id, group));
    if (e.kind === "clipboard" || e.kind === "assets" || e.kind === "colors") return run(store.update(e.kind, e.item.id, { groupID: group }));
  };

  const remove = (e: Entry) => {
    if (detailKey === keyOf(e)) setDetailKey(null);
    switch (e.kind) {
      case "captures": return run(ipc.historyDelete(e.item.id), "Moved to the Recycle Bin");
      case "clipboard": case "assets": case "colors": case "snippets": return run(store.remove(e.kind, [e.item.id]));
      case "notes":
        return onPrompt?.({ type: "confirm", title: "Delete this note?", message: firstLine(e.item.text), confirm: "Delete", onConfirm: () => run(island.noteDelete(e.item.id)) });
      case "tasks":
        return onPrompt?.({ type: "confirm", title: "Delete this task?", message: firstLine(e.item.text), confirm: "Delete", onConfirm: () => run(store.remove("tasks", [e.item.id])) });
    }
  };

  const rename = (e: Entry) => {
    switch (e.kind) {
      case "captures":
        return onPrompt?.({ type: "field", title: "Rename capture", initial: captureTitle(e.item), onSubmit: (v) => run(ipc.historyRename(e.item.id, v)) });
      case "assets":
        return onPrompt?.({ type: "field", title: "Rename file", initial: e.item.fileName.replace(/\.[^.]+$/, ""), onSubmit: (v) => run(island.assetRename(e.item.id, v)) });
      case "clipboard":
        return onPrompt?.({ type: "field", title: "Name this clipboard entry", initial: e.item.name, placeholder: "Name", onSubmit: (v) => run(store.update("clipboard", e.item.id, { name: v })) });
      case "colors":
        return onPrompt?.({ type: "field", title: "Name this color", initial: e.item.name, placeholder: "Name", onSubmit: (v) => run(store.update("colors", e.item.id, { name: v })) });
    }
  };

  const editSnippet = (s?: Snippet, text?: string) =>
    onPrompt?.({
      type: "snippet",
      title: s ? "Edit snippet" : "New snippet",
      initial: s ? { keyword: s.keyword, name: s.name, text: s.text } : text ? { keyword: ";", name: "", text } : undefined,
      onSubmit: (v) => {
        // A keyword is one snippet's: a new one with it replaces the old.
        const clash = snippets.find((x) => x.keyword === v.keyword && x.id !== s?.id);
        if (clash) store.remove("snippets", [clash.id]);
        run(s ? store.update("snippets", s.id, v) : store.put("snippets", { ...v, uses: 0 }));
        onStatus?.("Snippet saved", "checkmark.circle.fill", `Copy it from Snippets with ${v.keyword}`);
      },
    });
  const editNote = (n?: Note) =>
    onPrompt?.({
      type: "note",
      title: n ? "Edit note" : "New note",
      initial: n?.text,
      onSubmit: (text) => {
        run(island.noteSave(n?.id ?? null, text));
        onStatus?.("Note saved", "checkmark.circle.fill");
      },
    });

  const newGroup = (kind: GroupKind, then?: (g: Group) => void) =>
    onPrompt?.({
      type: "field",
      title: "New group",
      placeholder: "Name",
      submit: "Create",
      onSubmit: (name) => {
        const existing = groups.find((g) => g.kind === kind && g.name.toLowerCase() === name.toLowerCase());
        if (existing) return then?.(existing);
        store.put("groups", { kind, name }).then((g) => then?.(g)).catch(fail);
      },
    });

  const groupKind = (e: Entry): GroupKind | null => (e.kind === "captures" || e.kind === "clipboard" || e.kind === "colors" || e.kind === "assets" ? e.kind : null);
  const groupMenu = (e: Entry): MenuEntry => {
    const kind = groupKind(e);
    if (!kind) return null;
    const current = groupOf(e);
    return {
      text: "Group",
      items: [
        { text: "None", checked: !current, action: () => setGroup(e, null) },
        "-",
        ...groups.filter((g) => g.kind === kind).map((g) => ({ text: g.name, checked: current === g.id, action: () => setGroup(e, g.id) })),
        "-",
        { text: "New Group…", action: () => newGroup(kind, (g) => setGroup(e, g.id)) },
      ],
    };
  };

  const transformMenus = (text: string): MenuEntry[] => {
    const offered = applicable(text);
    const found = extract(text);
    return [
      { text: "Paste as", items: offered.map((t) => ({ text: TRANSFORM_TITLES[t], action: () => pasteWith(() => island.copyText(apply(t, text) ?? text, true)) })) },
      { text: "Copy as", items: offered.map((t) => ({ text: TRANSFORM_TITLES[t], action: () => run(island.copyText(apply(t, text) ?? text), "Copied") })) },
      found.length > 0 && {
        text: "Extract",
        items: found.map((g) => ({ text: `${g.title} (${g.values.length})`, action: () => run(island.copyText(g.values.join("\n")), "Copied") })),
      },
    ];
  };

  const capture = (m: "area" | "fullScreen" | "window" | "text") => {
    onDone?.();
    // A moment for the island or panel to get out of the picture.
    setTimeout(() => ipc.startCapture(m), m === "fullScreen" ? 220 : 60);
  };

  const menuFor = (e: Entry): MenuEntry[] => {
    switch (e.kind) {
      case "captures": {
        const c = e.item;
        return [
          { text: "Paste", action: () => paste(e) },
          { text: "Preview", action: () => setDetailKey(keyOf(e)) },
          { text: "Edit", action: () => { ipc.historyEdit(c.id); onDone?.(); } },
          { text: "Copy to Clipboard", action: () => copy(e) },
          { text: "Show in Explorer", action: () => run(ipc.historyReveal(c.id)) },
          { text: "Pin to Screen", action: () => { ipc.historyFloat(c.id); onDone?.(); } },
          { text: "Copy Share Link", action: () => { say("Uploading…"); run(ipc.historyShare(c.id), "Link copied"); } },
          { text: "Make Task…", action: () => onPrompt?.({ type: "task", title: "New task", projects, initial: { text: captureTitle(c), priority: "medium" }, onSubmit: (t) => store.put("tasks", { ...t, status: "pending", updatedAt: new Date().toISOString() }) }) },
          "-",
          { text: c.pinned ? "Unpin" : "Pin", action: () => togglePin(e) },
          groupMenu(e),
          { text: "Rename…", action: () => rename(e) },
          "-",
          { text: "Delete", action: () => remove(e) },
        ];
      }
      case "clipboard": {
        const c = e.item;
        const text = c.text ?? "";
        const colorValue = c.kind === "color" ? hexToColor(text) : null;
        return [
          { text: "Copy", action: () => copy(e) },
          { text: "Paste", action: () => paste(e) },
          { text: "Preview", action: () => setDetailKey(keyOf(e)) },
          c.kind === "link" && { text: "Open Link", action: () => run(island.openLink(text)) },
          colorValue && { text: "Copy as", items: FORMATS.map((f) => ({ text: `${FORMAT_TITLES[f]}  ${format(colorValue, f)}`, action: () => run(island.copyText(format(colorValue, f)), "Copied") })) },
          colorValue && { text: "Keep in Colors", action: () => run(store.put("colors", { color: colorValue }), "Saved to Colors") },
          ...((c.kind === "text" || c.kind === "link") ? transformMenus(text) : []),
          c.kind === "text" && { text: "Copy as Code Block", action: () => run(island.copyText("```\n" + text + "\n```"), "Copied") },
          c.kind === "files" && { text: "Show in Explorer", action: () => run(island.revealPath(text.split("\n")[0])) },
          c.kind === "image" && { text: "Save to Assets", action: () => run(island.clipCopy(c.id).then(() => island.assetsAddClipboard()), "Saved to Assets") },
          "-",
          { text: c.pinned ? "Unpin" : "Pin", action: () => togglePin(e) },
          groupMenu(e),
          { text: c.name ? "Rename…" : "Name…", action: () => rename(e) },
          (c.kind === "text" || c.kind === "link" || c.kind === "color") && { text: "Make Snippet…", action: () => editSnippet(undefined, text) },
          "-",
          { text: "Delete", action: () => remove(e) },
        ];
      }
      case "assets": {
        const a = e.item;
        return [
          { text: "Paste", action: () => paste(e) },
          { text: "Preview", action: () => setDetailKey(keyOf(e)) },
          { text: "Open", action: () => run(island.assetOpen(a.id)) },
          { text: "Copy", action: () => copy(e) },
          { text: "Show in Explorer", action: () => run(island.assetReveal(a.id)) },
          "-",
          { text: a.pinned ? "Unpin" : "Pin", action: () => togglePin(e) },
          groupMenu(e),
          { text: "Rename…", action: () => rename(e) },
          "-",
          { text: "Delete", action: () => remove(e) },
        ];
      }
      case "colors": {
        const c = e.item;
        return [
          { text: "Preview", action: () => setDetailKey(keyOf(e)) },
          { text: `Copy ${FORMAT_TITLES[colorFormat]}`, action: () => copy(e) },
          { text: "Copy as", items: FORMATS.map((f) => ({ text: `${FORMAT_TITLES[f]}  ${format(c.color, f)}`, action: () => { setColorFormat(f); run(island.copyText(format(c.color, f)), "Copied"); } })) },
          { text: "Paste", action: () => paste(e) },
          "-",
          { text: c.pinned ? "Unpin" : "Pin", action: () => togglePin(e) },
          groupMenu(e),
          { text: c.name ? "Rename…" : "Name…", action: () => rename(e) },
          "-",
          { text: "Delete", action: () => remove(e) },
        ];
      }
      case "snippets":
        return [
          { text: "Copy", action: () => copy(e) },
          { text: "Paste", action: () => paste(e) },
          { text: "Edit…", action: () => editSnippet(e.item) },
          "-",
          { text: "Delete", action: () => remove(e) },
        ];
      case "notes":
        return [
          { text: "Edit…", action: () => editNote(e.item) },
          { text: "Copy as Markdown", action: () => copy(e) },
          { text: "Paste", action: () => paste(e) },
          "-",
          { text: "Show in Explorer", action: () => run(island.noteReveal(e.item.id)) },
          { text: "Delete", action: () => remove(e) },
        ];
      case "tasks": {
        const t = e.item;
        return [
          { text: "Open", action: () => editTask(t) },
          { text: "Status", items: STATUS_ORDER.map((s) => ({ text: STATUS_TITLES[s], checked: t.status === s, action: () => store.update("tasks", t.id, { status: s, updatedAt: new Date().toISOString() }) })) },
          { text: "Priority", items: PRIORITY_ORDER.map((p) => ({ text: PRIORITY_TITLES[p], checked: t.priority === p, action: () => store.update("tasks", t.id, { priority: p, updatedAt: new Date().toISOString() }) })) },
          "-",
          { text: "Delete…", action: () => remove(e) },
        ];
      }
      case "answers":
        return [
          { text: "Copy", action: () => copy(e) },
          { text: "Paste", action: () => paste(e) },
          e.item.color && { text: "Keep in Colors", action: () => run(store.put("colors", { color: e.item.color }), "Saved to Colors") },
        ];
    }
  };

  const editTask = (t: TaskItem) =>
    onPrompt?.({
      type: "task",
      title: "Edit task",
      projects,
      initial: { text: t.text, projectID: t.projectID, priority: t.priority },
      onSubmit: (v) => store.update("tasks", t.id, { text: v.text, projectID: v.projectID ?? null, priority: v.priority, updatedAt: new Date().toISOString() }),
    });

  /** A card's click: copy, mostly; open for notes and tasks; Open for assets. */
  const tap = (e: Entry) => {
    switch (e.kind) {
      case "notes": return editNote(e.item);
      case "tasks": return editTask(e.item);
      case "assets": return run(island.assetOpen(e.item.id));
      case "colors": copy(e); return say(`Copied ${FORMAT_TITLES[colorFormat]}`);
      default: return copy(e);
    }
  };

  const showMenu = (ev: React.MouseEvent, e: Entry) => {
    ev.preventDefault();
    popup(menuFor(e), onMenu);
  };

  // MARK: Cards

  const card = (e: Entry, size?: { width: number | string; height: number }) => {
    const key = keyOf(e);
    const frame = {
      key,
      copied: copiedKey === key,
      selected: detailKey === key,
      style: size ? { width: size.width, height: size.height } : undefined,
      onClick: () => tap(e),
      onContextMenu: (ev: React.MouseEvent) => showMenu(ev, e),
      className: mode === "floating" ? "quick" : "",
    };
    const pin = (pinned?: boolean) => <CardAction symbol={pinned ? "pin.slash.fill" : "pin"} help={pinned ? "Unpin" : "Pin"} tint={pinned ? "#ffd60a" : undefined} onClick={() => togglePin(e)} />;
    const trash = <CardAction symbol="trash" help="Remove" tint="#ff453a" onClick={() => remove(e)} />;
    const preview = <CardAction symbol="eye" help="Preview" onClick={() => setDetailKey(key)} />;
    switch (e.kind) {
      case "captures":
        return (
          <CardFrame {...frame} title={captureTitle(e.item)} caption={captureCaption(e.item)} trailing={preview}
            actions={<><CopyAction onCopy={() => copy(e)} /><CardAction symbol="pencil" help="Edit" onClick={() => { ipc.historyEdit(e.item.id); onDone?.(); }} />{pin(e.item.pinned)}{trash}</>}>
            <CaptureCardBody item={e.item} version={version} />
          </CardFrame>
        );
      case "clipboard":
        return (
          <CardFrame {...frame} caption={clipCaption(e.item)} className={`${frame.className} clip-${e.item.kind}`} trailing={preview}
            actions={<><CopyAction onCopy={() => copy(e)} />{pin(e.item.pinned)}{trash}</>}>
            <ClipCardBody item={e.item} />
          </CardFrame>
        );
      case "assets":
        return (
          <CardFrame {...frame} title={e.item.fileName} caption={assetCaption(e.item)} trailing={preview}
            actions={<><CopyAction onCopy={() => copy(e)} /><CardAction symbol="arrow.up.forward.app" help="Open" onClick={() => run(island.assetOpen(e.item.id))} />{pin(e.item.pinned)}{trash}</>}>
            <AssetCardBody item={e.item} />
          </CardFrame>
        );
      case "colors":
        return (
          <CardFrame {...frame} caption={colorCaption(e.item, colorFormat)} trailing={preview}
            actions={<><CopyAction onCopy={() => copy(e)} />{pin(e.item.pinned)}{trash}</>}>
            <ColorCardBody item={e.item} />
          </CardFrame>
        );
      case "snippets":
        return (
          <CardFrame {...frame} caption={snippetCaption(e.item)}
            actions={<><CopyAction onCopy={() => copy(e)} /><CardAction symbol="pencil" help="Edit" onClick={() => editSnippet(e.item)} />{trash}</>}>
            <SnippetCardBody item={e.item} />
          </CardFrame>
        );
      case "notes":
        return (
          <CardFrame {...frame} caption={noteCaption(e.item)} trailing={preview}
            actions={<><CopyAction onCopy={() => copy(e)} /><CardAction symbol="pencil" help="Edit" onClick={() => editNote(e.item)} />{trash}</>}>
            <NoteCardBody item={e.item} />
          </CardFrame>
        );
      case "tasks":
        return (
          <CardFrame {...frame}
            actions={<><CardAction symbol="checkmark" help={nextStatusTitle(e.item)} onClick={() => store.update("tasks", e.item.id, { status: NEXT_STATUS[e.item.status], updatedAt: new Date().toISOString() })} /><CardAction symbol="arrow.up.forward.app" help="Open" onClick={() => editTask(e.item)} /></>}>
            <TaskCardBody item={e.item} project={projectName(e.item.projectID)} />
          </CardFrame>
        );
      case "answers":
        return (
          <CardFrame {...frame} className={`${frame.className} answer-card`}
            actions={<><CopyAction onCopy={() => copy(e)} /><CardAction symbol="arrow.down.doc" help="Paste" onClick={() => paste(e)} />{e.item.color && <CardAction symbol="paintpalette" help="Keep in Colors" onClick={() => run(store.put("colors", { color: e.item.color }), "Saved to Colors")} />}</>}>
            <AnswerCardBody answer={e.item} />
          </CardFrame>
        );
    }
  };

  // MARK: Shown list

  const tabEntries = useMemo(() => applyFilter(entriesFor(tab), filter, tab), [tab, filter, captures, clipboard, assets, colors, snippets, notes, tasks]);
  const searchEntries: Entry[] = useMemo(() => {
    if (!results) return [];
    const a: Entry[] = answers.map((item) => ({ kind: "answers", item }));
    if (searchTab === "answers") return a;
    const kept = results.filter((g) => !searchTab || g.tab === searchTab).flatMap((g) => g.entries);
    return [...a, ...kept];
  }, [results, answers, searchTab]);
  const visible = searching ? searchEntries : tab === "tasks" ? [] : tabEntries;

  useEffect(() => {
    if (dropping) {
      setSearch("");
      setTab("assets");
    }
  }, [dropping]);

  const detail = detailKey ? visible.find((e) => keyOf(e) === detailKey) : undefined;
  useEffect(() => {
    if (detailKey && !detail) setDetailKey(null);
  }, [detailKey, detail]);
  useEffect(() => setDetailKey(null), [searching]);

  // MARK: Keyboard

  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      const typing = ev.target instanceof HTMLInputElement || ev.target instanceof HTMLTextAreaElement;
      if (ev.ctrlKey && /^[1-8]$/.test(ev.key)) {
        ev.preventDefault();
        setSearch("");
        setTab(TABS[Number(ev.key) - 1].id);
      } else if (ev.ctrlKey && ev.key.toLowerCase() === "f") {
        ev.preventDefault();
        onWantsKeyboard?.();
        searchField.current?.focus();
      } else if ((ev.key === "ArrowLeft" || ev.key === "ArrowRight") && !ev.ctrlKey && !ev.altKey && (!typing || !search)) {
        const list = visible.filter((e) => e.kind !== "answers" && e.kind !== "tasks");
        if (!list.length) return;
        ev.preventDefault();
        const at = detailKey ? list.findIndex((e) => keyOf(e) === detailKey) : -1;
        const next = at < 0 ? 0 : Math.min(list.length - 1, Math.max(0, at + (ev.key === "ArrowRight" ? 1 : -1)));
        setDetailKey(keyOf(list[next]));
      } else if (ev.key === "Escape" && detailKey) {
        ev.preventDefault();
        ev.stopImmediatePropagation();
        setDetailKey(null);
      } else if (ev.key === "Enter" && detail && !typing) {
        ev.preventDefault();
        copy(detail);
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  });

  // MARK: Header

  const header =
    mode === "island" ? (
      <div className="panel-header">
        <SearchField
          ref={searchField}
          value={search}
          onChange={(v) => {
            setSearch(v);
            setSearchTab(null);
          }}
          onFocus={onWantsKeyboard}
          summary={searching ? (resultCount ? `${resultCount} ${resultCount === 1 ? "match" : "matches"}` : "No matches") : undefined}
        />
        {!searching && (
          <div className="capture-bar">
            <HoverButton symbol="viewfinder" help="Capture area" onClick={() => capture("area")} />
            <HoverButton symbol="display" help="Capture full screen" onClick={() => capture("fullScreen")} />
            <HoverButton
              symbol="ellipsis"
              help="More tools"
              onClick={() =>
                popup(
                  [
                    { text: "Capture Window", action: () => capture("window") },
                    { text: "Capture Text", action: () => capture("text") },
                    "-",
                    { text: "Settings…", action: () => { ipc.runAction("showSettings"); onDone?.(); } },
                  ],
                  onMenu,
                )
              }
            />
          </div>
        )}
      </div>
    ) : (
      <div className="panel-header floating">
        <SearchField ref={searchField} capsule autoFocus value={search} onChange={(v) => { setSearch(v); setSearchTab(null); }} />
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

  // The tab's own buttons and its Clear menu.
  const clearItem: Record<string, { title: string; run: () => void } | undefined> = {
    captures: captures.some((c) => !c.pinned && !c.groupID) ? { title: "Clear Unpinned Captures", run: () => onPrompt?.({ type: "confirm", title: "Clear unpinned captures?", message: "They go to the Recycle Bin.", confirm: "Clear", onConfirm: () => run(island.clearUnpinnedCaptures()) }) } : undefined,
    clipboard: clipboard.some((c) => !c.pinned && !c.groupID) ? { title: "Clear Unpinned Entries", run: () => run(store.clearUnpinned("clipboard")) } : undefined,
    colors: colors.some((c) => !c.pinned && !c.groupID) ? { title: "Clear Unpinned Colors", run: () => run(store.clearUnpinned("colors")) } : undefined,
    assets: assets.some((c) => !c.pinned && !c.groupID) ? { title: "Clear Recent Assets", run: () => run(store.clearUnpinned("assets")) } : undefined,
  };
  const tabButtons: ReactNode = (
    <>
      {(tab === "snippets" || tab === "notes") && (
        <QuietButton symbol="plus" title="New" onClick={() => (tab === "snippets" ? editSnippet() : editNote())} />
      )}
      {tab === "assets" && (
        <QuietButton
          symbol="arrow.down.doc"
          title="Paste"
          onClick={() =>
            island.assetsAddClipboard().then((n) => say(n === 0 ? "No image or file on the clipboard" : n === 1 ? "Saved to Assets" : `${n} saved to Assets`), fail)
          }
        />
      )}
      {clearItem[tab] && (
        <HoverButton symbol="ellipsis" help="More" small onClick={() => popup([{ text: clearItem[tab]!.title, action: clearItem[tab]!.run }], onMenu)} />
      )}
    </>
  );

  const tabRow = searching ? (
    <div className="tab-row results">
      <button className={`result-pill ${!searchTab ? "on" : ""}`} onClick={() => setSearchTab(null)}>
        All <span className="count">{resultCount}</span>
      </button>
      {answers.length > 0 && (
        <button className={`result-pill ${searchTab === "answers" ? "on" : ""}`} onClick={() => setSearchTab("answers")}>
          Answers <span className="count">{answers.length}</span>
        </button>
      )}
      {results?.map((g) => (
        <button key={g.tab} className={`result-pill ${searchTab === g.tab ? "on" : ""}`} onClick={() => setSearchTab(g.tab)}>
          {TABS.find((t) => t.id === g.tab)!.title} <span className="count">{g.entries.length}</span>
        </button>
      ))}
      <span className="row-spacer" />
      <span className="esc-hint">Esc to clear</span>
    </div>
  ) : (
    <div className="tab-row" role="tablist">
      {TABS.map((t, i) => (
        <button key={t.id} role="tab" aria-selected={tab === t.id} title={`${t.title}  Ctrl+${i + 1}`} className={`tab-pill ${tab === t.id ? "on" : ""}`} onClick={() => setTab(t.id)}>
          {t.title}
          <span className="count">{count(t.id)}</span>
        </button>
      ))}
      <span className="row-spacer" />
      {tabButtons}
    </div>
  );

  // MARK: Strip of Recent / Pinned / groups

  const groupKindFor: Partial<Record<Tab, GroupKind>> = { captures: "captures", clipboard: "clipboard", colors: "colors", assets: "assets" };
  const groupSymbol: Record<GroupKind, IconName> = { captures: "photo.on.rectangle", clipboard: "doc.on.clipboard", colors: "paintpalette", assets: "tray.full" };
  const strip = !searching && GROUPED.includes(tab) && (
    <div className="chip-strip">
      <Chip on={filter === "recent"} symbol="clock" title="Recent" onClick={() => setFilter("recent")} />
      <Chip on={filter === "pinned"} symbol="pin" title="Pinned" onClick={() => setFilter("pinned")} />
      <span className="chip-divider" />
      {groups
        .filter((g) => (tab === "all" ? true : g.kind === groupKindFor[tab]))
        .map((g) => (
          <Chip
            key={g.id}
            on={filter === g.id}
            symbol={tab === "all" ? groupSymbol[g.kind] : "folder"}
            title={g.name}
            onClick={() => setFilter(g.id)}
            onContextMenu={(ev) => {
              ev.preventDefault();
              popup(
                [
                  { text: "Rename…", action: () => onPrompt?.({ type: "field", title: "Rename group", initial: g.name, onSubmit: (name) => run(store.update("groups", g.id, { name })) }) },
                  "-",
                  { text: "Delete Group", action: () => { if (filter === g.id) setFilter("recent"); run(store.remove("groups", [g.id])); } },
                ],
                onMenu,
              );
            }}
          />
        ))}
      {tab !== "all" && groupKindFor[tab] && (
        <Chip
          symbol="plus"
          title={groups.some((g) => g.kind === groupKindFor[tab]) ? undefined : "New group"}
          onClick={() => newGroup(groupKindFor[tab]!, (g) => setFilter(g.id))}
        />
      )}
    </div>
  );

  // MARK: Empty states

  const emptyText = (): { symbol: IconName; title: string; action?: { title: string; run: () => void } } => {
    if (searching) return { symbol: "magnifyingglass", title: `Nothing matches “${search.trim()}”` };
    if (GROUPED.includes(tab) && filter === "pinned") return { symbol: "pin", title: "Nothing pinned" };
    if (GROUPED.includes(tab) && filter !== "recent") return { symbol: "folder", title: "Nothing in this group yet — Group › on a card's menu" };
    switch (tab) {
      case "captures": return { symbol: "camera.viewfinder", title: "No captures yet", action: { title: "Capture area", run: () => capture("area") } };
      case "clipboard": return { symbol: "doc.on.clipboard", title: "Nothing copied yet" };
      case "assets": return { symbol: "tray.full", title: "Drop images or files here to keep them handy" };
      case "colors": return { symbol: "paintpalette", title: "Colors you keep show here — copy a hex value, then Keep in Colors" };
      case "snippets": return { symbol: "text.badge.plus", title: "Text you use often, a click away", action: { title: "New snippet", run: () => editSnippet() } };
      case "notes": return { symbol: "note.text", title: "Jot things down", action: { title: "New note", run: () => editNote() } };
      default: return { symbol: "square.grid.2x2", title: "Nothing yet — capture, copy or drop something", action: { title: "Capture area", run: () => capture("area") } };
    }
  };
  const empty = (() => {
    const e = emptyText();
    return (
      <div className="panel-empty">
        <Icon name={e.symbol} size={32} />
        <div className="empty-title">{e.title}</div>
        {e.action && (
          <button className="empty-action" onClick={e.action.run}>
            {e.action.title}
          </button>
        )}
      </div>
    );
  })();

  // MARK: Detail

  const detailButtons = (e: Entry): DetailButton[] => {
    const copyButton = { title: "Copy", symbol: "doc.on.doc" as IconName, onClick: () => copy(e) };
    const pinButton = (pinned?: boolean) => ({ title: pinned ? "Unpin" : "Pin", symbol: (pinned ? "pin.slash.fill" : "pin") as IconName, onClick: () => togglePin(e) });
    switch (e.kind) {
      case "captures": return [copyButton, { title: "Edit", symbol: "pencil", onClick: () => { ipc.historyEdit(e.item.id); onDone?.(); } }, { title: "Pin to Screen", symbol: "macwindow", onClick: () => { ipc.historyFloat(e.item.id); onDone?.(); } }, pinButton(e.item.pinned)];
      case "clipboard": return [copyButton, ...(e.item.kind === "link" ? [{ title: "Open", symbol: "safari" as IconName, onClick: () => run(island.openLink(e.item.text ?? "")) }] : []), pinButton(e.item.pinned)];
      case "assets": return [copyButton, { title: "Open", symbol: "arrow.up.forward.app", onClick: () => run(island.assetOpen(e.item.id)) }, { title: "Show", symbol: "folder", onClick: () => run(island.assetReveal(e.item.id)) }, pinButton(e.item.pinned)];
      case "colors": return [pinButton(e.item.pinned)];
      case "snippets": return [copyButton, { title: "Edit", symbol: "pencil", onClick: () => editSnippet(e.item) }];
      case "notes": return [copyButton, { title: "Edit", symbol: "pencil", onClick: () => editNote(e.item) }, { title: "Show", symbol: "folder", onClick: () => run(island.noteReveal(e.item.id)) }];
      default: return [];
    }
  };

  // MARK: Layout

  let content: ReactNode;
  if (detail && detail.kind !== "answers" && detail.kind !== "tasks") {
    content = (
      <Detail
        entry={detail as DetailItem}
        version={version}
        buttons={detailButtons(detail)}
        colorFormat={colorFormat}
        onCopyText={(text, f) => {
          if (f) setColorFormat(f);
          run(island.copyText(text), "Copied");
        }}
        onBack={() => setDetailKey(null)}
        onRevealPath={(p) => run(island.revealPath(p))}
      />
    );
  } else if (!searching && tab === "tasks") {
    content = <TasksView tasks={tasks} projects={projects} onPrompt={(p) => onPrompt?.(p)} onMenu={onMenu} onStatus={(t, s) => say(t || s)} />;
  } else if (visible.length === 0) {
    content = empty;
  } else if (searching && results) {
    const sections = [
      ...(answers.length && (!searchTab || searchTab === "answers") ? [{ title: "Answers", entries: answers.map((item) => ({ kind: "answers", item }) as Entry) }] : []),
      ...results.filter((g) => !searchTab || g.tab === searchTab).map((g) => ({ title: TABS.find((t) => t.id === g.tab)!.title, entries: g.entries })),
    ];
    content = mode === "island" ? <Strip sections={sections} card={card} /> : <Grid sections={sections} card={card} />;
  } else {
    const sections = dayGroups(visible, tab !== "all" && filter !== "recent" && filter !== "pinned");
    content = mode === "island" ? <Strip sections={sections} card={card} /> : <Grid sections={sections} card={card} />;
  }

  return (
    <div className={`panel ${mode}`}>
      {header}
      {!detail && tabRow}
      {content}
      {!detail && strip}
      {toast && <div className="panel-toast" role="status">{toast}</div>}
      {dropping && (
        <div className="drop-overlay">
          <Icon name="tray.and.arrow.down" size={28} />
          Drop to save as an asset
        </div>
      )}
    </div>
  );
}

// MARK: - Helpers

function hexToColor(text: string) {
  const m = /^#([0-9A-F]{6})$/i.exec(text.trim());
  if (!m) return null;
  return { red: parseInt(m[1].slice(0, 2), 16) / 255, green: parseInt(m[1].slice(2, 4), 16) / 255, blue: parseInt(m[1].slice(4, 6), 16) / 255, alpha: 1 };
}

/** A snippet's blanks that need nothing asked: the date, the time, a UUID. */
function expand(template: string): string {
  const now = new Date();
  return template.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (whole, name: string) => {
    switch (name.toLowerCase()) {
      case "date": return now.toLocaleDateString();
      case "time": return now.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
      case "datetime": return now.toLocaleString();
      case "uuid": return crypto.randomUUID().toUpperCase();
      case "cursor": return "";
      default: return whole;
    }
  });
}

type Section = { title: string; entries: Entry[] };

/** Consecutive entries of a day share a header; a group's pinned ones come first. */
function dayGroups(entries: Entry[], pinnedFirst: boolean): Section[] {
  const sections: Section[] = [];
  for (const e of entries) {
    const title = pinnedFirst && pinnedOf(e) ? "Pinned" : dayTitle(new Date(dateOf(e)));
    const last = sections[sections.length - 1];
    if (last && last.title === title) last.entries.push(e);
    else sections.push({ title, entries: [e] });
  }
  return sections;
}

/** Cards in one row, under small headers; scrolls sideways by wheel or drag. */
function Strip({ sections, card }: { sections: Section[]; card: (e: Entry) => ReactNode }) {
  const row = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ start: false, end: false });
  const drag = useRef<{ x: number; left: number; moved: boolean } | null>(null);

  const measure = () => {
    const el = row.current;
    if (!el) return;
    setEdges({ start: el.scrollLeft > 0, end: el.scrollLeft < el.scrollWidth - el.clientWidth - 1 });
  };
  useEffect(measure, [sections]);

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
          if (Math.abs(e.clientX - d.x) > 5) d.moved = true;
          if (d.moved) row.current.scrollLeft = d.left - (e.clientX - d.x);
        }}
        onPointerUp={() => setTimeout(() => (drag.current = null))}
        onClickCapture={(e) => {
          // The click that ends a drag is not a click on a card.
          if (drag.current?.moved) e.stopPropagation();
        }}
      >
        {sections.map((s) => (
          <section key={s.title + keyOf(s.entries[0])} className="strip-group">
            <h3>{s.title}</h3>
            <div className="strip-cards">{s.entries.map((e) => card(e))}</div>
          </section>
        ))}
      </div>
      <div className={`fade start ${edges.start ? "on" : ""}`} />
      <div className={`fade end ${edges.end ? "on" : ""}`} />
    </div>
  );
}

/** The floating panel's grid: the same sections, as rows of equal columns. */
function Grid({ sections, card }: { sections: Section[]; card: (e: Entry, size: { width: string; height: number }) => ReactNode }) {
  return (
    <div className="grid-scroll">
      {sections.map((s) => (
        <section key={s.title + keyOf(s.entries[0])}>
          <h3>{s.title}</h3>
          <div className="grid">{s.entries.map((e) => card(e, { width: "100%", height: 150 }))}</div>
        </section>
      ))}
    </div>
  );
}

const SearchField = forwardRef<HTMLInputElement, { value: string; onChange: (v: string) => void; onFocus?: () => void; summary?: string; capsule?: boolean; autoFocus?: boolean }>(
  function SearchField({ value, onChange, onFocus, summary, capsule, autoFocus }, ref) {
    const on = value.trim().length > 0;
    return (
      <label className={`search ${capsule ? "capsule" : ""} ${on ? "on" : ""}`} onMouseDown={() => onFocus?.()}>
        <Icon name="magnifyingglass" size={14} weight={STROKE.medium} />
        <input
          ref={ref}
          autoFocus={autoFocus}
          value={value}
          placeholder="Search everything"
          spellCheck={false}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape" && value) {
              e.stopPropagation();
              onChange("");
              (e.target as HTMLInputElement).blur();
            }
          }}
          aria-label="Search"
        />
        {on && (
          <>
            {summary && <span className="matches">{summary}</span>}
            <button className="clear" title="Clear the search" onClick={() => onChange("")}>
              <Icon name="xmark.circle.fill" size={15} />
            </button>
          </>
        )}
      </label>
    );
  },
);

function Chip({ on, symbol, title, onClick, onContextMenu }: { on?: boolean; symbol: IconName; title?: string; onClick: () => void; onContextMenu?: (e: React.MouseEvent) => void }) {
  return (
    <button className={`chip ${on ? "on" : ""} ${title ? "" : "icon-only"}`} onClick={onClick} onContextMenu={onContextMenu} title={title ?? "New group"}>
      <Icon name={symbol} size={11} weight={STROKE.semibold} />
      {title}
    </button>
  );
}

function HoverButton({ symbol, help, onClick, small }: { symbol: IconName; help: string; onClick: () => void; small?: boolean }) {
  return (
    <button className={`hover-button ${small ? "small" : ""}`} title={help} aria-label={help} onClick={onClick}>
      <Icon name={symbol} size={small ? 14 : 15} weight={STROKE.medium} />
    </button>
  );
}

function QuietButton({ symbol, title, onClick }: { symbol: IconName; title: string; onClick: () => void }) {
  return (
    <button className="quiet-button" onClick={onClick}>
      <Icon name={symbol} size={12} weight={STROKE.semibold} /> {title}
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
