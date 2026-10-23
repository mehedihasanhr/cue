// Typed calls into Cue Studio's Rust side.

import { convertFileSrc, invoke } from "@tauri-apps/api/core";

export type Target = { kind: "display"; index: number } | { kind: "window"; hwnd: number };
export type DisplayInfo = { index: number; name: string; x: number; y: number; width: number; height: number; scale: number; primary: boolean };
export type WindowInfo = { hwnd: number; title: string; app: string; x: number; y: number; width: number; height: number };
export type Microphone = { id: string; name: string };
export type RecordingState = { recording: boolean; paused: boolean; seconds: number };
export type StartOptions = {
  target: Target;
  area?: [number, number, number, number] | null;
  systemAudio: boolean;
  microphone: boolean;
  microphoneId?: string | null;
  microphoneName?: string | null;
  frameRate: number;
  quality: "good" | "better" | "best";
};
export type LibraryItem = {
  path: string;
  name: string;
  createdAt: string;
  duration: number;
  width: number;
  height: number;
  edited: boolean;
  unfinished: boolean;
};
export type ProjectFiles = {
  path: string;
  manifest: Manifest;
  project: unknown | null;
  pendingCrop: { rect: [[number, number], [number, number]] } | null;
  cursor: string;
  input: string;
  cursorArtwork: Record<string, { width: number; height: number; hotspotX: number; hotspotY: number; path: string }> | null;
};
export type Track = { kind: string; path: string; pixelSize?: [number, number]; frameRate?: number; codec?: string; name?: string; deviceID?: string };
export type Manifest = {
  formatVersion: number;
  name: string;
  createdAt: string;
  duration: number;
  displayScale: number;
  sourceRect?: [[number, number], [number, number]];
  tracks: Track[];
  telemetry: { cursor?: string; input?: string; cursorArtwork?: string; pointerLatency?: number; keys?: string };
  recordedBy: string;
};

export const studio = {
  displays: () => invoke<DisplayInfo[]>("displays"),
  windows: () => invoke<WindowInfo[]>("windows_list"),
  microphones: () => invoke<Microphone[]>("microphones"),
  start: (options: StartOptions) => invoke<void>("start_recording", { options }),
  pause: () => invoke<void>("pause_recording"),
  resume: () => invoke<void>("resume_recording"),
  stop: () => invoke<string>("stop_recording"),
  cancel: () => invoke<void>("cancel_recording"),
  state: () => invoke<RecordingState>("recording_state"),
  library: () => invoke<LibraryItem[]>("library"),
  openLibrary: () => invoke<void>("open_library"),
  openEditor: (path: string) => invoke<void>("open_editor", { path }),
  readProject: (path: string) => invoke<ProjectFiles>("read_project", { path }),
  writeProject: (path: string, project: unknown) => invoke<void>("write_project", { path, project }),
  reveal: (path: string) => invoke<void>("reveal_recording", { path }),
  openFile: (path: string) => invoke<void>("open_file", { path }),
  remove: (path: string) => invoke<void>("delete_recording", { path }),
  openPicker: (mode: "display" | "window" | "area") => invoke<void>("open_picker", { mode }),
  closePicker: () => invoke<void>("close_picker"),
  showBar: () => invoke<void>("show_bar"),
};

/** A file in a recording, as a URL a <video> or <img> can load (with seeking). */
export function fileUrl(packagePath: string, relative: string): string {
  const sep = packagePath.includes("\\") ? "\\" : "/";
  return convertFileSrc(`${packagePath}${sep}${relative.split("/").join(sep)}`);
}

export function message(error: unknown): string {
  return typeof error === "string" ? error : error instanceof Error ? error.message : String(error);
}

/** "1:05", "12:40", "1:02:03". */
export function clockText(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

export type VideoInfo = { width: number; height: number; timescale: number; codec: string; description: number[]; times: number[]; syncs: number[] };

/** The export's file work (see `media.rs`). */
export const media = {
  open: (path: string) => invoke<VideoInfo>("video_open", { path }),
  read: (path: string, from: number, count: number) => invoke<ArrayBuffer>("video_read", { path, from, count }),
  close: (path: string) => invoke<void>("video_close", { path }),
  begin: (path: string) => invoke<void>("export_begin", { path }),
  write: (path: string, position: number, data: Uint8Array) =>
    invoke<void>("export_write", data, { headers: { "x-path": encodeURIComponent(path), "x-position": String(position) } }),
  end: (path: string, keep: boolean) => invoke<void>("export_end", { path, keep }),
};

/** A path inside a recording, with the platform's separator. */
export function joinPath(packagePath: string, relative: string): string {
  const sep = packagePath.includes("\\") ? "\\" : "/";
  return `${packagePath}${sep}${relative.split("/").join(sep)}`;
}
