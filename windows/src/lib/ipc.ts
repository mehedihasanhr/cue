// Typed calls into the Rust side.

import { invoke } from "@tauri-apps/api/core";

export type AfterCapture = "edit" | "copy";
export type Mode = "area" | "window" | "fullScreen" | "text";

export type ShareSettings = {
  provider: "off" | "s3" | "custom";
  endpoint: string;
  region: string;
  bucket: string;
  prefix: string;
  accessKey: string;
  publicBase: string;
  customUrl: string;
  customMethod: "PUT" | "POST";
  customHeaderName: string;
  customResponseKey: string;
  datedNames: boolean;
};

export type IslandSettings = {
  enabled: boolean;
  /** "primary", "all", or one display's id. */
  display: string;
  showPill: boolean;
  openMode: "hover" | "click";
  hoverDelay: number;
  closeOnLeave: boolean;
  closeDelay: number;
  opensOn: string;
  flashCaptures: boolean;
  flashDuration: number;
  statuses: boolean;
  animation: "lively" | "quick" | "none";
};

export type Settings = {
  share: ShareSettings;
  island: IslandSettings;
  panels: { position: string; columns: number };
  capture: { sound: boolean };
  clipboard: { enabled: boolean; limit: number };
  updates: { automatic: boolean };
  studio: { countdownSeconds: number; systemAudio: boolean; microphone: boolean; opensEditorAfterRecording: boolean };
  editor: unknown;
  afterCapture: AfterCapture;
  copyToClipboard: boolean;
  saveFolder: string | null;
  shortcuts: Record<string, string>;
  appearance: "system" | "light" | "dark";
};

export type Conflict = { action: string; accelerator: string; message: string };
export type Rect = { x: number; y: number; width: number; height: number };

export type WindowInfo = { rect: Rect; title: string; app: string };
export type OverlayInfo = {
  mode: Mode;
  imageUrl: string;
  width: number;
  height: number;
  scale: number;
  windows: WindowInfo[];
  pointer: [number, number] | null;
};

export type HistoryItem = {
  id: string;
  fileName: string;
  createdAt: string;
  pixelWidth: number;
  pixelHeight: number;
  scale: number;
  pinned: boolean;
  groupID?: string;
  url: string;
  thumbnailUrl: string;
  path: string;
};

export const ipc = {
  getSettings: () => invoke<Settings>("get_settings"),
  setSettings: (settings: Settings) => invoke<Conflict[]>("set_settings", { settings }),
  shortcutConflicts: () => invoke<Conflict[]>("shortcut_conflicts"),
  pauseShortcuts: (paused: boolean) => invoke<void>("pause_shortcuts", { paused }),
  defaultFolder: () => invoke<string>("default_folder"),
  getAutostart: () => invoke<boolean>("get_autostart"),
  setAutostart: (enabled: boolean) => invoke<void>("set_autostart", { enabled }),
  runAction: (action: string) => invoke<void>("run_action", { action }),
  defaultShortcuts: () => invoke<Record<string, string>>("default_shortcuts"),
  appInfo: () => invoke<{ exe: string; os: string }>("app_info"),
  revealApp: () => invoke<void>("reveal_app"),
  openWindowsSettings: (page: "keyboard" | "language") => invoke<void>("open_windows_settings", { page }),

  startCapture: (mode: Mode) => invoke<void>("start_capture", { mode }),
  overlayInfo: (index: number) => invoke<OverlayInfo>("overlay_info", { index }),
  overlayReady: (index: number, focus: boolean) => invoke<void>("overlay_ready", { index, focus }),
  finishCapture: (index: number, rect: Rect) => invoke<void>("finish_capture", { index, rect }),
  cancelCapture: () => invoke<void>("cancel_capture"),

  historyItems: () => invoke<HistoryItem[]>("history_items"),
  historyItem: (id: string) => invoke<HistoryItem>("history_item_by_id", { id }),
  historyDelete: (id: string) => invoke<void>("history_delete", { id }),
  historyRename: (id: string, title: string) => invoke<void>("history_rename", { id, title }),
  historySetPinned: (id: string, pinned: boolean) => invoke<void>("history_set_pinned", { id, pinned }),
  historyCopy: (id: string) => invoke<void>("history_copy", { id }),
  historyReveal: (id: string) => invoke<void>("history_reveal", { id }),
  historyOpenFolder: () => invoke<void>("history_open_folder"),
  historyEdit: (id: string) => invoke<void>("history_edit", { id }),
  historyFloat: (id: string) => invoke<void>("history_float", { id }),
  historyShare: (id: string) => invoke<string>("history_share", { id }),
  shareSecretStatus: () => invoke<Record<string, boolean>>("share_secret_status"),
  setShareSecret: (name: string, value: string) => invoke<void>("set_share_secret", { name, value }),

  editorSave: (id: string, png: Uint8Array) =>
    invoke<void>("editor_save", png, { headers: { "x-capture-id": id } }),
  editorCopy: (png: Uint8Array) => invoke<void>("editor_copy", png),
  editorWriteFile: (path: string, data: Uint8Array) =>
    invoke<void>("editor_write_file", data, { headers: { "x-path": encodeURIComponent(path) } }),
  copyText: (text: string) => invoke<void>("copy_text", { textValue: text }),
};

/** The message in whatever a command threw. */
export function message(error: unknown): string {
  return typeof error === "string" ? error : error instanceof Error ? error.message : String(error);
}
