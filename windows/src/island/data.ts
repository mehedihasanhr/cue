// The island's data: every kind of item the tabs show, the calls that change them, and
// hooks that keep a view in step as the Rust side announces changes.

import { invoke } from "@tauri-apps/api/core";
import { useEffect, useState } from "react";
import { useEvent } from "../lib/hooks";
import { ipc, type HistoryItem } from "../lib/ipc";
import type { PickedColor } from "./colormath";

export type ClipKind = "text" | "link" | "color" | "image" | "files";
export type ClipItem = {
  id: string;
  kind: ClipKind;
  text?: string;
  pixelWidth?: number;
  pixelHeight?: number;
  sourceName?: string;
  createdAt: string;
  pinned?: boolean;
  name?: string;
  groupID?: string;
};
export type Asset = {
  id: string;
  fileName: string;
  kind: "image" | "file";
  byteSize: number;
  pixelWidth?: number;
  pixelHeight?: number;
  createdAt: string;
  pinned?: boolean;
  groupID?: string;
};
export type ColorItem = { id: string; color: PickedColor; createdAt: string; name?: string; pinned?: boolean; groupID?: string };
export type Snippet = { id: string; keyword: string; name: string; text: string; assetID?: string; createdAt: string; uses: number };
export type Note = { id: string; text: string; createdAt: string; updatedAt: string };
export type TaskStatus = "pending" | "inProcess" | "review" | "complete";
export type Priority = "urgent" | "high" | "medium" | "low";
export type TaskItem = {
  id: string;
  text: string;
  projectID?: string;
  status: TaskStatus;
  priority: Priority;
  createdAt: string;
  updatedAt: string;
};
export type Project = { id: string; name: string; parentID?: string; createdAt: string };
export type GroupKind = "captures" | "clipboard" | "colors" | "assets";
export type Group = { id: string; kind: GroupKind; name: string; createdAt: string };

type Collections = {
  clipboard: ClipItem;
  colors: ColorItem;
  assets: Asset;
  snippets: Snippet;
  tasks: TaskItem;
  projects: Project;
  groups: Group;
};
export type CollectionName = keyof Collections;

export const store = {
  list: <K extends CollectionName>(kind: K) => invoke<Collections[K][]>("store_list", { kind }),
  put: <K extends CollectionName>(kind: K, item: Partial<Collections[K]>) => invoke<Collections[K]>("store_put", { kind, item }),
  update: <K extends CollectionName>(kind: K, id: string, patch: Record<string, unknown>) =>
    invoke<Collections[K]>("store_update", { kind, id, patch }),
  remove: (kind: CollectionName, ids: string[]) => invoke<void>("store_delete", { kind, ids }),
  clearUnpinned: (kind: CollectionName) => invoke<void>("store_clear_unpinned", { kind }),
};

export const island = {
  clipCopy: (id: string) => invoke<void>("clip_copy", { id }),
  copyText: (text: string, paste = false) => invoke<boolean>("copy_text_and_paste", { textValue: text, paste }),
  paste: (kind: "clipboard" | "captures" | "assets", id: string) => invoke<boolean>("paste_item", { kind, id }),
  forgetFront: () => invoke<void>("forget_front"),
  assetsAddPaths: (paths: string[]) => invoke<number>("assets_add_paths", { paths }),
  assetsAddClipboard: () => invoke<number>("assets_add_clipboard"),
  assetCopy: (id: string) => invoke<void>("asset_copy", { id }),
  assetOpen: (id: string) => invoke<void>("asset_open", { id }),
  assetReveal: (id: string) => invoke<void>("asset_reveal", { id }),
  assetRename: (id: string, title: string) => invoke<void>("asset_rename", { id, title }),
  notes: () => invoke<Note[]>("notes_list"),
  noteSave: (id: string | null, text: string) => invoke<string>("note_save", { id, textValue: text }),
  noteDelete: (id: string) => invoke<void>("note_delete", { id }),
  noteReveal: (id: string) => invoke<void>("note_reveal", { id }),
  captureGroup: (id: string, group: string | null) => invoke<void>("history_set_group", { id, group }),
  clearUnpinnedCaptures: () => invoke<number>("history_clear_unpinned"),
  openLink: (url: string) => invoke<void>("open_link", { url }),
  revealPath: (path: string) => invoke<void>("reveal_path", { path }),
};

/** A collection, reloaded whenever it changes. */
export function useCollection<K extends CollectionName>(kind: K): Collections[K][] {
  const [items, setItems] = useState<Collections[K][]>([]);
  const load = () => store.list(kind).then(setItems).catch(() => {});
  useEffect(() => {
    load();
  }, [kind]);
  useEvent<string>("store-changed", (changed) => changed === kind && load());
  return items;
}

export function useCaptures(): { items: HistoryItem[]; version: number } {
  const [state, setState] = useState<{ items: HistoryItem[]; version: number }>({ items: [], version: 0 });
  const load = () => ipc.historyItems().then((items) => setState((s) => ({ items, version: s.version + 1 })));
  useEffect(() => {
    load();
  }, []);
  useEvent("library-changed", load);
  return state;
}

export function useNotes(): Note[] {
  const [notes, setNotes] = useState<Note[]>([]);
  const load = () => island.notes().then(setNotes).catch(() => {});
  useEffect(() => {
    load();
  }, []);
  useEvent<string>("store-changed", (changed) => changed === "notes" && load());
  return notes;
}

/** Where pictures come from: `klik://` on the Mac test bed, `http://klik.localhost` on Windows. */
export function klikUrl(path: string): string {
  return navigator.userAgent.includes("Windows") ? `http://klik.localhost/${path}` : `klik://localhost/${path}`;
}

// MARK: - Words for things

/** The first line of a task or note, with the Markdown taken off. */
export function firstLine(text: string): string {
  const line = text
    .split("\n")
    .map((l) => l.trim().replace(/^#+\s*/, "").replace(/^[-*>]\s+/, "").replace(/^\[[ xX]\]\s*/, "").trim())
    .find((l) => l.length > 0);
  return (line ?? "").replace(/\*\*/g, "").replace(/`/g, "");
}

/** What follows a note's title, for its card. */
export function summary(text: string): string {
  const lines = text.split("\n");
  const first = lines.findIndex((l) => l.trim().length > 0);
  return lines
    .slice(first + 1)
    .join("\n")
    .replace(/^#+\s*/gm, "")
    .replace(/\*\*/g, "")
    .trim();
}

export const STATUS_TITLES: Record<TaskStatus, string> = { pending: "Pending", inProcess: "In process", review: "Review", complete: "Complete" };
export const STATUS_ORDER: TaskStatus[] = ["inProcess", "pending", "review", "complete"];
export const STATUS_COLORS: Record<TaskStatus, string> = {
  pending: "rgba(255,255,255,0.55)",
  inProcess: "#0a84ff",
  review: "#ff9f0a",
  complete: "#30d158",
};
export const NEXT_STATUS: Record<TaskStatus, TaskStatus> = { pending: "inProcess", inProcess: "review", review: "complete", complete: "pending" };
export const PRIORITY_TITLES: Record<Priority, string> = { urgent: "Urgent", high: "High", medium: "Medium", low: "Low" };
export const PRIORITY_ORDER: Priority[] = ["urgent", "high", "medium", "low"];
export const PRIORITY_COLORS: Record<Priority, string> = { urgent: "#ff453a", high: "#ff9f0a", medium: "rgba(255,255,255,0.55)", low: "#64d2ff" };
export const PRIORITY_SYMBOLS = { urgent: "flame.fill", high: "chevron.up.2", medium: "equal", low: "chevron.down" } as const;

/** "1.2 MB" */
export function byteSize(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

/** "Today", "Yesterday", "Wed, Jul 22", or "Jul 22, 2025" in another year. */
export function dayTitle(date: Date, now = new Date()): string {
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (date.toDateString() === now.toDateString()) return "Today";
  if (date.toDateString() === yesterday.toDateString()) return "Yesterday";
  if (date.getFullYear() === now.getFullYear()) return date.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function timeOf(iso: string): string {
  return new Date(iso).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}
