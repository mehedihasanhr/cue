// Settings, laid out as the Mac's (`App/SettingsRoot.swift`, `App/SettingsView.swift`):
// a sidebar card on the left — search on top, a tile per page, app-wide pages first and
// then a group per feature — and the chosen page on the right under the back and
// forward pill. Every page is cards of rows built from `controls.tsx`.

import { getVersion } from "@tauri-apps/api/app";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { open } from "@tauri-apps/plugin-dialog";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import appIcon from "../../src-tauri/icons/128x128@2x.png";
import { DEFAULT_PREFS, editorDefaults, RANGES, type EditorDefaults } from "../editor/prefs";
import { css, PALETTE, type RGBA } from "../editor/model/types";
import { useAppearance, useEvent, useShowWhenReady } from "../lib/hooks";
import { ipc, message, type Conflict, type IslandSettings, type Settings as Prefs } from "../lib/ipc";
import { Icon, type IconName } from "../ui/icon";
import { display, fromEvent } from "./accelerator";
import {
  Cell,
  Field,
  Group,
  Pane,
  PreviewPicker,
  Row,
  Segmented,
  Select,
  seconds,
  Slider,
  Stepper,
  Switch,
  SymbolTile,
  type Tint,
} from "./controls";
import "./settings.css";

// MARK: - Sections

type Section = "general" | "appearance" | "shortcuts" | "sharing" | "about" | "island" | "capture" | "editor" | "clipboard" | "studio";

const SECTIONS: Record<Section, { title: string; subtitle: string; symbol: IconName; tint: Tint; keywords: string[] }> = {
  general: {
    title: "General",
    subtitle: "Startup, the tray and where captures go",
    symbol: "gearshape.fill",
    tint: "gray",
    keywords: ["login", "startup", "launch", "sign in", "folder", "storage", "pictures", "save", "clipboard"],
  },
  appearance: {
    title: "Appearance",
    subtitle: "The theme, in the editor, the panels and this window",
    symbol: "paintpalette.fill",
    tint: "plum",
    keywords: ["theme", "dark", "light", "system", "mode", "look"],
  },
  shortcuts: {
    title: "Shortcuts",
    subtitle: "The keys that reach Cue from any app",
    symbol: "command",
    tint: "indigo",
    keywords: ["hotkey", "keyboard", "keys", "global", "bindings", "record", "print screen"],
  },
  sharing: {
    title: "Sharing",
    subtitle: "Where Copy Share Link uploads captures",
    symbol: "link",
    tint: "blue",
    keywords: ["upload", "s3", "r2", "bucket", "link", "url", "cloud", "endpoint", "custom", "credential"],
  },
  about: {
    title: "About",
    subtitle: "Screenshots you can annotate, blur and share — on Windows",
    symbol: "info",
    tint: "brand",
    keywords: ["version", "build", "update", "privacy", "stackrover", "copyright"],
  },
  island: {
    title: "Island",
    subtitle: "How the Dynamic Island opens, closes, looks and moves",
    symbol: "rectangle.topthird.inset.filled",
    tint: "brand",
    keywords: ["dynamic island", "notch", "pill", "panel", "position", "hover", "click", "delay", "open", "close", "flash", "status", "animation", "tab", "columns"],
  },
  capture: {
    title: "Capture",
    subtitle: "What happens after a capture, and its sound",
    symbol: "camera.fill",
    tint: "orange",
    keywords: ["after", "editor", "copy", "clipboard", "sound", "shutter", "audio"],
  },
  clipboard: {
    title: "Clipboard",
    subtitle: "What Cue remembers of what you copy",
    symbol: "doc.on.clipboard.fill",
    tint: "teal",
    keywords: ["history", "copy", "paste", "limit", "items", "clear", "pinned"],
  },
  studio: {
    title: "Studio",
    subtitle: "Record the screen, then edit it in Cue Studio",
    symbol: "record.circle.fill",
    tint: "red",
    keywords: ["record", "recording", "video", "screen", "countdown", "microphone", "system audio", "studio", "edit videos"],
  },
  editor: {
    title: "Editor",
    subtitle: "What every new annotation starts as",
    symbol: "paintbrush.pointed.fill",
    tint: "purple",
    keywords: ["annotation", "color", "stroke", "width", "shape", "arrow", "fill", "text", "font", "marker", "highlighter", "blur", "pixelate", "counter", "defaults"],
  },
};

const GROUPS: Section[][] = [
  ["general", "appearance", "shortcuts", "sharing", "about"],
  ["island", "capture", "editor", "clipboard", "studio"],
];

function matches(section: Section, query: string): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  const s = SECTIONS[section];
  return s.title.toLowerCase().includes(needle) || s.subtitle.toLowerCase().includes(needle) || s.keywords.some((k) => k.includes(needle));
}

const SECTION_KEY = "cue.settings.section";

/** The page asked for in the address (`#island`), else the one shown last. */
function savedSection(): Section {
  const asked = location.hash.slice(1);
  if (asked in SECTIONS) return asked as Section;
  try {
    const value = localStorage.getItem(SECTION_KEY) as Section | null;
    if (value && value in SECTIONS) return value;
  } catch {
    // No storage: start at General.
  }
  return "general";
}

/** The pages visited, for back and forward. */
function useNavigation() {
  const [state, setState] = useState(() => ({ history: [savedSection()], cursor: 0 }));
  const section = state.history[state.cursor];
  useEffect(() => {
    try {
      localStorage.setItem(SECTION_KEY, section);
    } catch {
      // Remembering the page is a convenience.
    }
  }, [section]);
  return {
    section,
    canGoBack: state.cursor > 0,
    canGoForward: state.cursor < state.history.length - 1,
    go: (next: Section) =>
      setState((s) => (s.history[s.cursor] === next ? s : { history: [...s.history.slice(0, s.cursor + 1), next], cursor: s.cursor + 1 })),
    back: () => setState((s) => ({ ...s, cursor: Math.max(0, s.cursor - 1) })),
    forward: () => setState((s) => ({ ...s, cursor: Math.min(s.history.length - 1, s.cursor + 1) })),
  };
}

type Save = (patch: Partial<Prefs>) => void;

// MARK: - Root

export default function Settings() {
  useAppearance();
  const [prefs, setPrefs] = useState<Prefs | null>(null);
  const [conflicts, setConflicts] = useState<Conflict[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const nav = useNavigation();
  const search = useRef<HTMLInputElement>(null);
  const latest = useRef<Prefs | null>(null);

  useEffect(() => {
    Promise.all([ipc.getSettings(), ipc.shortcutConflicts()]).then(([p, c]) => {
      latest.current = p;
      setPrefs(p);
      setConflicts(c);
    });
  }, []);
  useShowWhenReady(prefs !== null);
  useEvent<string>("settings:go", (page) => page in SECTIONS && nav.go(page as Section));

  // Ctrl+F searches, Ctrl+[ and Ctrl+] (or Alt+← →) go back and forward, as ⌘ does on the Mac.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.ctrlKey && event.key.toLowerCase() === "f") {
        event.preventDefault();
        search.current?.focus();
        search.current?.select();
      } else if ((event.ctrlKey && event.key === "[") || (event.altKey && event.key === "ArrowLeft")) {
        event.preventDefault();
        nav.back();
      } else if ((event.ctrlKey && event.key === "]") || (event.altKey && event.key === "ArrowRight")) {
        event.preventDefault();
        nav.forward();
      } else if (event.ctrlKey && event.key.toLowerCase() === "w") {
        event.preventDefault();
        getCurrentWindow().close();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const filtered = useMemo(() => GROUPS.map((g) => g.filter((s) => matches(s, query))).filter((g) => g.length > 0), [query]);

  // Typing narrows the list; the page stays if it is still there, else the first match shows.
  useEffect(() => {
    const visible = filtered.flat();
    if (visible.length && !visible.includes(nav.section)) nav.go(visible[0]);
  }, [filtered]);

  if (!prefs) return null;

  const save: Save = (patch) => {
    const next = { ...latest.current!, ...patch };
    latest.current = next;
    setPrefs(next);
    ipc
      .setSettings(next)
      .then((c) => {
        setConflicts(c);
        setError(null);
      })
      .catch((e) => setError(message(e)));
  };

  const page: Record<Section, () => ReactNode> = {
    general: () => <General prefs={prefs} save={save} />,
    appearance: () => <Appearance prefs={prefs} save={save} />,
    shortcuts: () => <Shortcuts prefs={prefs} save={save} conflicts={conflicts} />,
    sharing: () => <Sharing prefs={prefs} save={save} />,
    about: () => <About prefs={prefs} save={save} />,
    island: () => <Island prefs={prefs} save={save} />,
    capture: () => <Capture prefs={prefs} save={save} />,
    editor: () => <Editor prefs={prefs} save={save} />,
    clipboard: () => <Clipboard prefs={prefs} save={save} />,
    studio: () => <Studio prefs={prefs} save={save} />,
  };

  return (
    <div className="settings">
      <aside className="sidebar">
        <div className="sidebar-drag" data-tauri-drag-region />
        <label className="search">
          <Icon name="magnifyingglass" size={14} weight={2} />
          <input
            ref={search}
            value={query}
            placeholder="Search settings…"
            spellCheck={false}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") {
                setQuery("");
                e.currentTarget.blur();
              }
            }}
          />
          {query && (
            <button className="search-clear" aria-label="Clear search" onClick={() => setQuery("")}>
              <Icon name="xmark.circle.fill" size={14} />
            </button>
          )}
        </label>
        <nav className="sidebar-list" aria-label="Settings">
          {filtered.map((group, index) => (
            <div className="sidebar-group" key={index}>
              {group.map((id) => (
                <button key={id} className={`sidebar-row ${nav.section === id ? "on" : ""}`} aria-current={nav.section === id ? "page" : undefined} onClick={() => nav.go(id)}>
                  {id === "about" ? (
                    <img className="app-tile" src={appIcon} width={22} height={22} alt="" />
                  ) : (
                    <span className="sidebar-tile">
                      <SymbolTile symbol={SECTIONS[id].symbol} tint={SECTIONS[id].tint} size={22} />
                    </span>
                  )}
                  <span>{SECTIONS[id].title}</span>
                </button>
              ))}
            </div>
          ))}
          {filtered.length === 0 && (
            <div className="sidebar-empty">
              <Icon name="magnifyingglass" size={22} />
              <div>No Results for “{query.trim()}”</div>
            </div>
          )}
        </nav>
      </aside>

      <main className="detail" aria-label={`${SECTIONS[nav.section].title} settings`}>
        <div className="detail-drag" data-tauri-drag-region />
        <div className="history-pill">
          <button aria-label="Back" title="Back (Ctrl+[)" disabled={!nav.canGoBack} onClick={nav.back}>
            <Icon name="chevron.left" size={13} weight={2.2} />
          </button>
          <span className="history-divider" />
          <button aria-label="Forward" title="Forward (Ctrl+])" disabled={!nav.canGoForward} onClick={nav.forward}>
            <Icon name="chevron.right" size={13} weight={2.2} />
          </button>
        </div>
        <CaptionButtons />
        <div className="detail-scroll" key={nav.section}>
          {error && (
            <div className="error-banner" role="alert">
              <Icon name="exclamationmark.triangle.fill" size={14} />
              {error}
            </div>
          )}
          {page[nav.section]()}
        </div>
      </main>
    </div>
  );
}

/** Minimise, maximise and close, in a pill at the top right where Windows keeps them. */
function CaptionButtons() {
  const window = getCurrentWindow();
  return (
    <div className="caption-buttons">
      <button aria-label="Minimize" title="Minimize" onClick={() => window.minimize()}>
        <Icon name="minus" size={13} weight={2} />
      </button>
      <button aria-label="Maximize" title="Maximize" onClick={() => window.toggleMaximize()}>
        <Icon name="rectangle" size={11} weight={2} />
      </button>
      <button className="close" aria-label="Close" title="Close" onClick={() => window.close()}>
        <Icon name="xmark" size={13} weight={2} />
      </button>
    </div>
  );
}

// MARK: - General

function General({ prefs, save }: { prefs: Prefs; save: Save }) {
  const [autostart, setAutostart] = useState<boolean | null>(null);
  const [launchError, setLaunchError] = useState<string | null>(null);
  const [defaultFolder, setDefaultFolder] = useState("");
  useEffect(() => {
    ipc.getAutostart().then(setAutostart);
    ipc.defaultFolder().then(setDefaultFolder);
  }, []);
  const folder = prefs.saveFolder ?? defaultFolder;
  const custom = prefs.saveFolder !== null;

  return (
    <Pane>
      <Group>
        <Row title="Launch Cue when you sign in" subtitle="It waits in the tray, ready for its shortcuts.">
          <Switch
            label="Launch at sign-in"
            checked={!!autostart}
            onChange={(on) => {
              setAutostart(on);
              ipc
                .setAutostart(on)
                .then(() => setLaunchError(null))
                .catch((e) => {
                  setLaunchError(message(e));
                  ipc.getAutostart().then(setAutostart);
                });
            }}
          />
        </Row>
        {launchError && <Row title={launchError} symbol="xmark.circle.fill" tint="red" />}
      </Group>

      <Group title="Storage">
        <Row title={custom ? lastComponent(folder) : "Pictures › Cue"} subtitle={folder} symbol="folder" tint="orange">
          <span className="row-buttons">
            <button
              className="button"
              onClick={async () => {
                const chosen = await open({ directory: true, defaultPath: folder });
                if (typeof chosen === "string") save({ saveFolder: chosen });
              }}
            >
              Choose…
            </button>
            <button className="icon-button" title="Show in File Explorer" aria-label="Show in File Explorer" onClick={() => ipc.historyOpenFolder()}>
              <Icon name="arrow.up.forward.app" size={15} />
            </button>
          </span>
        </Row>
        {custom && (
          <Row title="Default folder" subtitle="Pictures › Cue">
            <button className="button" onClick={() => save({ saveFolder: null })}>
              Use Default Folder
            </button>
          </Row>
        )}
      </Group>
    </Pane>
  );
}

function lastComponent(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

// MARK: - Appearance

function Appearance({ prefs, save }: { prefs: Prefs; save: Save }) {
  return (
    <Pane>
      <Group title="Theme">
        <PreviewPicker
          title="Theme"
          value={prefs.appearance}
          options={[
            { value: "system", title: "Auto" },
            { value: "light", title: "Light" },
            { value: "dark", title: "Dark" },
          ]}
          onChange={(appearance) => save({ appearance })}
          preview={(value) => <AppearancePreview appearance={value} />}
        />
      </Group>
    </Pane>
  );
}

/** A desktop in the light, the dark, or half of each: wallpaper, taskbar, and a window with its sidebar. */
function AppearancePreview({ appearance }: { appearance: Prefs["appearance"] }) {
  const desktop = (dark: boolean) => (
    <span className={`desktop ${dark ? "dark" : "light"}`}>
      <span className="desktop-window">
        <span className="desktop-sidebar" />
        <span className="desktop-lines">
          <i />
          <i />
          <i />
        </span>
      </span>
      <span className="desktop-taskbar" />
    </span>
  );
  if (appearance === "system") {
    return (
      <span className="desktop-split">
        {desktop(false)}
        <span className="desktop-half">{desktop(true)}</span>
      </span>
    );
  }
  return desktop(appearance === "dark");
}

// MARK: - Shortcuts

const ACTIONS: { id: string; title: string; symbol: IconName; tint: Tint }[] = [
  { id: "captureFullScreen", title: "Capture full screen", symbol: "display", tint: "blue" },
  { id: "captureArea", title: "Capture area", symbol: "viewfinder", tint: "teal" },
  { id: "captureWindow", title: "Capture window", symbol: "macwindow", tint: "cyan" },
  { id: "captureText", title: "Capture text (OCR)", symbol: "text.viewfinder", tint: "green" },
  { id: "showHistory", title: "Cue panel at the pointer", symbol: "cursorarrow.rays", tint: "orange" },
];

function Shortcuts({ prefs, save, conflicts }: { prefs: Prefs; save: Save; conflicts: Conflict[] }) {
  const usesPrintScreen = Object.values(prefs.shortcuts).some((a) => /PrintScreen/i.test(a));
  return (
    <Pane>
      {usesPrintScreen && (
        <Group>
          <Row
            title="A binding uses the Print Screen key"
            subtitle="Turn off “Use the Print screen key to open screen capture” in Windows Settings › Accessibility › Keyboard."
            symbol="exclamationmark.triangle.fill"
            tint="orange"
          >
            <button className="button" onClick={() => ipc.openWindowsSettings("keyboard")}>
              Keyboard Settings…
            </button>
          </Row>
        </Group>
      )}

      <Group title="Global shortcuts">
        {ACTIONS.map((action) => {
          const accelerator = prefs.shortcuts[action.id] ?? "";
          const conflict = conflicts.find((c) => c.action === action.id);
          return (
            <Row key={action.id} title={action.title} symbol={action.symbol} tint={action.tint}>
              <span className="row-buttons">
                <ShortcutRecorder
                  value={accelerator}
                  label={action.title}
                  onChange={(value) => save({ shortcuts: { ...prefs.shortcuts, [action.id]: value } })}
                />
                <ShortcutStatus accelerator={accelerator} conflict={conflict} />
              </span>
            </Row>
          );
        })}
      </Group>

      <Group>
        <Row title="Defaults">
          <button className="button" onClick={() => ipc.defaultShortcuts().then((shortcuts) => save({ shortcuts }))}>
            Restore Defaults
          </button>
        </Row>
      </Group>
    </Pane>
  );
}

function ShortcutStatus({ accelerator, conflict }: { accelerator: string; conflict?: Conflict }) {
  if (!accelerator)
    return (
      <span className="shortcut-status unassigned" title="No shortcut assigned">
        <Icon name="minus.circle" size={16} />
      </span>
    );
  if (conflict)
    return (
      <span className="shortcut-status conflict" title={conflict.message || "Another app already uses this shortcut"}>
        <Icon name="xmark.circle.fill" size={16} />
      </span>
    );
  return (
    <span className="shortcut-status active" title="Active">
      <Icon name="checkmark.circle.fill" size={16} />
    </span>
  );
}

/** Keycaps in a well; click it and press the new keys. Backspace clears, Esc keeps it. */
function ShortcutRecorder({ value, onChange, label }: { value: string; onChange: (value: string) => void; label: string }) {
  const [recording, setRecording] = useState(false);

  useEffect(() => {
    if (!recording) return;
    ipc.pauseShortcuts(true);
    const onKey = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.key === "Escape") return setRecording(false);
      if (event.key === "Backspace" || event.key === "Delete") {
        onChange("");
        return setRecording(false);
      }
      const accelerator = fromEvent(event);
      if (accelerator) {
        onChange(accelerator);
        setRecording(false);
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      ipc.pauseShortcuts(false);
    };
  }, [recording]);

  return (
    <button
      className={`recorder ${recording ? "recording" : ""}`}
      onClick={() => setRecording(!recording)}
      onBlur={() => setRecording(false)}
      aria-label={recording ? `Press the new shortcut for ${label}` : `${label}: ${value || "none"}`}
    >
      {recording ? (
        <span className="recorder-hint">Type shortcut…</span>
      ) : value ? (
        display(value).map((key) => (
          <kbd key={key} className={key.length > 1 ? "wide" : ""}>
            {key}
          </kbd>
        ))
      ) : (
        <span className="recorder-hint">Record Shortcut</span>
      )}
    </button>
  );
}

// MARK: - Sharing

function Sharing({ prefs, save }: { prefs: Prefs; save: Save }) {
  const share = prefs.share;
  const [secrets, setSecrets] = useState<Record<string, boolean>>({});
  const set = (patch: Partial<Prefs["share"]>) => save({ share: { ...share, ...patch } });
  useEffect(() => {
    ipc.shareSecretStatus().then(setSecrets);
  }, []);

  const text = (title: string, key: keyof Prefs["share"], placeholder = "", subtitle?: string) => (
    <Row title={title} subtitle={subtitle}>
      <Field label={title} value={share[key] as string} placeholder={placeholder} onCommit={(value) => set({ [key]: value })} />
    </Row>
  );

  const secret = (title: string, name: string) => (
    <Row title={title} subtitle={secrets[name] ? "Kept in Windows Credential Manager." : "Not set."}>
      <Field
        label={title}
        secret
        value=""
        placeholder={secrets[name] ? "••••••••" : ""}
        onCommit={(value) => value && ipc.setShareSecret(name, value).then(() => ipc.shareSecretStatus().then(setSecrets))}
      />
    </Row>
  );

  return (
    <Pane>
      <Group title="Upload to">
        <Row title="Service" subtitle="Copy Share Link uploads a capture and puts its link on the clipboard.">
          <Select
            label="Service"
            value={share.provider}
            onChange={(provider) => set({ provider })}
            options={[
              { value: "off", title: "Off" },
              { value: "s3", title: "S3-compatible bucket" },
              { value: "custom", title: "Custom endpoint" },
            ]}
          />
        </Row>
        <Row title="Name uploads by date" subtitle="Off, a short random name — harder to guess.">
          <Switch label="Name uploads by date" checked={share.datedNames} onChange={(on) => set({ datedNames: on })} />
        </Row>
      </Group>
      {share.provider === "s3" && (
        <Group title="Bucket">
          {text("Endpoint", "endpoint", "s3.us-east-1.amazonaws.com", "AWS S3, Cloudflare R2, MinIO, Backblaze B2…")}
          {text("Region", "region", "auto")}
          {text("Bucket", "bucket")}
          {text("Folder", "prefix", "cue/")}
          {text("Access key", "accessKey")}
          {secret("Secret key", "share.s3.secretKey")}
          {text("Public URL", "publicBase", "https://cdn.example.com", "What goes before the file name in the link.")}
        </Group>
      )}
      {share.provider === "custom" && (
        <Group title="Endpoint">
          {text("URL", "customUrl", "https://example.com/upload/{name}", "{name} becomes the file name.")}
          <Row title="Method" subtitle="PUT sends the PNG; POST sends it as a form field named “file”.">
            <Segmented
              label="Method"
              value={share.customMethod}
              onChange={(customMethod) => set({ customMethod })}
              options={[
                { value: "PUT", title: "PUT" },
                { value: "POST", title: "POST" },
              ]}
            />
          </Row>
          {text("Header", "customHeaderName", "Authorization")}
          {secret("Header value", "share.custom.headerValue")}
          {text("Link in the answer", "customResponseKey", "url", "For a JSON answer, where the link is, like data.link.")}
        </Group>
      )}
    </Pane>
  );
}

// MARK: - About

function About({ prefs, save }: { prefs: Prefs; save: Save }) {
  const [version, setVersion] = useState("");
  const [info, setInfo] = useState<{ exe: string; os: string } | null>(null);
  const [folder, setFolder] = useState("");
  const [copied, setCopied] = useState(false);
  const [update, setUpdate] = useState<{ version: string | null; ready: boolean }>({ version: null, ready: false });
  const [status, setStatus] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  useEffect(() => {
    getVersion().then(setVersion);
    ipc.appInfo().then(setInfo);
    ipc.defaultFolder().then((f) => setFolder(prefs.saveFolder ?? f));
    invoke<{ version: string | null; ready: boolean }>("update_state").then(setUpdate);
  }, [prefs.saveFolder]);
  useEvent<{ version: string | null; ready: boolean }>("update-changed", setUpdate);

  async function checkForUpdates() {
    setWorking(true);
    setStatus("Checking…");
    try {
      const found = await invoke<{ version: string | null; ready: boolean }>("update_check");
      setUpdate(found);
      setStatus(found.version ? null : "You have the newest version.");
    } catch (error) {
      setStatus(`Couldn't check: ${message(error)}`);
    } finally {
      setWorking(false);
    }
  }

  async function install() {
    setWorking(true);
    setStatus(update.ready ? "Installing…" : "Downloading…");
    try {
      // Cue closes here, and the installer opens the new one.
      await invoke("update_install");
    } catch (error) {
      setStatus(`Couldn't install: ${message(error)}`);
      setWorking(false);
    }
  }

  const automatic = prefs.updates.automatic;
  const updateText =
    status ??
    (update.version
      ? update.ready
        ? `Cue ${update.version} is downloaded. It installs when you step away, or when you quit Cue.`
        : `Cue ${update.version} is available.`
      : "Cue looks for a newer version every few hours.");

  return (
    <Pane>
      <Group>
        <Cell vertical={16}>
          <img className="about-icon" src={appIcon} width={56} height={56} alt="" />
          <div className="row-text">
            <div className="about-name">Cue</div>
            <div className="row-subtitle">Screenshots you can annotate, blur and share — built for Windows.</div>
          </div>
          <div className="row-subtitle about-version">Version {version}</div>
        </Cell>
        <Row title="Version">
          <button
            className="button"
            onClick={() => {
              ipc.copyText(`Cue ${version} · ${info?.os ?? "Windows"}`);
              setCopied(true);
              window.setTimeout(() => setCopied(false), 1500);
            }}
          >
            {copied ? "Copied" : "Copy"}
          </button>
        </Row>
        <Row title="Windows">
          <span className="row-value">{info?.os}</span>
        </Row>
        <Row title="Updates" subtitle={updateText}>
          {update.version ? (
            <button className="button primary" disabled={working} onClick={install}>
              Install and Restart
            </button>
          ) : (
            <button className="button" disabled={working} onClick={checkForUpdates}>
              Check for Updates
            </button>
          )}
        </Row>
        <Row
          title="Install updates"
          subtitle={automatic ? "Downloaded quietly, installed when you step away from the PC or quit Cue." : "Cue tells you when there is one; you install it here."}
        >
          <Segmented
            label="Install updates"
            value={automatic ? "auto" : "ask"}
            onChange={(v) => save({ updates: { automatic: v === "auto" } })}
            options={[
              { value: "auto", title: "Automatically" },
              { value: "ask", title: "Ask First" },
            ]}
          />
        </Row>
      </Group>

      <Group title="On this PC">
        <Row title="Cue" subtitle={info?.exe}>
          <button className="button" onClick={() => ipc.revealApp()}>
            Show in Explorer
          </button>
        </Row>
        <Row title="Captures" subtitle={folder}>
          <button className="button" onClick={() => ipc.historyOpenFolder()}>
            Show in Explorer
          </button>
        </Row>
      </Group>

      <Group>
        <Row title="Privacy" subtitle="Captures stay on this PC unless you share one.">
          <a className="button" href="https://mehedihasanhr.github.io/klik/privacy/" target="_blank" rel="noreferrer">
            Privacy Policy
          </a>
        </Row>
        <Row title={`© ${new Date().getFullYear()} Stackrover`} />
      </Group>
    </Pane>
  );
}

// MARK: - Island

const PANEL_POSITIONS: { value: string; title: string }[] = [
  { value: "pointer", title: "Pointer" },
  { value: "top", title: "Top" },
  { value: "center", title: "Center" },
  { value: "bottom", title: "Bottom" },
  { value: "topLeft", title: "Top Left" },
  { value: "topRight", title: "Top Right" },
  { value: "bottomLeft", title: "Bottom Left" },
  { value: "bottomRight", title: "Bottom Right" },
];

function Island({ prefs, save }: { prefs: Prefs; save: Save }) {
  const island = prefs.island;
  const [displays, setDisplays] = useState<{ id: string; title: string; primary: boolean }[]>([]);
  useEffect(() => {
    const look = () => invoke<{ id: string; title: string; primary: boolean }[]>("island_displays").then(setDisplays);
    look();
    // A display plugged in while Settings is open shows when it is come back to.
    window.addEventListener("focus", look);
    return () => window.removeEventListener("focus", look);
  }, []);
  const set = (patch: Partial<IslandSettings>) => save({ island: { ...island, ...patch } });
  const off = !island.enabled;
  return (
    <Pane>
      <Group title="Dynamic Island">
        <Row title="Show the Dynamic Island" subtitle="A pill at the top of the screen that opens into Cue.">
          <Switch label="Show the island" checked={island.enabled} onChange={(enabled) => set({ enabled })} />
        </Row>
        <Row title="Display" subtitle="Where the island sits. A display that's unplugged hands it back to the main one." disabled={off}>
          <Select
            label="Display"
            disabled={off}
            value={island.display}
            onChange={(display) => set({ display })}
            options={[
              { value: "primary", title: "Main display" },
              { value: "all", title: "Every display" },
              ...displays.filter((d) => !d.primary || displays.length > 1).map((d) => ({ value: d.id, title: d.title })),
              ...(island.display !== "primary" && island.display !== "all" && !displays.some((d) => d.id === island.display) ? [{ value: island.display, title: "A display not connected now" }] : []),
            ]}
          />
        </Row>
        <Row title="Pill background" subtitle="Black while closed, so it can be found. Off, it hides until it opens." disabled={off}>
          <Switch label="Pill background" checked={island.showPill} disabled={off} onChange={(showPill) => set({ showPill })} />
        </Row>
      </Group>

      <Group title="Opening and closing" disabled={off}>
        <Row title="Open on" disabled={off}>
          <Segmented
            label="Open on"
            disabled={off}
            value={island.openMode}
            onChange={(openMode) => set({ openMode })}
            options={[
              { value: "hover", title: "Hover" },
              { value: "click", title: "Click" },
            ]}
          />
        </Row>
        {island.openMode === "hover" && (
          <Row title="Hover delay" disabled={off}>
            <Slider
              label="Hover delay"
              disabled={off}
              value={island.hoverDelay}
              min={0}
              max={1.5}
              step={0.05}
              caption={seconds(island.hoverDelay, 0, "At once")}
              onChange={(hoverDelay) => set({ hoverDelay })}
            />
          </Row>
        )}
        <Row title="Close when the pointer leaves" disabled={off}>
          <Switch label="Close on leave" checked={island.closeOnLeave} disabled={off} onChange={(closeOnLeave) => set({ closeOnLeave })} />
        </Row>
        {island.closeOnLeave && (
          <Row title="Close delay" disabled={off}>
            <Slider
              label="Close delay"
              disabled={off}
              value={island.closeDelay}
              min={0.1}
              max={3}
              step={0.05}
              caption={seconds(island.closeDelay, 0.1, "At once")}
              onChange={(closeDelay) => set({ closeDelay })}
            />
          </Row>
        )}
        <Row title="Opens on" disabled={off}>
          <Select
            label="Opens on"
            disabled={off}
            value={island.opensOn}
            onChange={(opensOn) => set({ opensOn })}
            options={[
              { value: "", title: "Last used" },
              { value: "all", title: "All" },
              { value: "captures", title: "Captures" },
            ]}
          />
        </Row>
      </Group>

      <Group title="What it shows" disabled={off}>
        <Row title="Flash new captures" disabled={off}>
          <Switch label="Flash captures" checked={island.flashCaptures} disabled={off} onChange={(flashCaptures) => set({ flashCaptures })} />
        </Row>
        {island.flashCaptures && (
          <Row title="For" disabled={off}>
            <Slider
              label="Flash duration"
              disabled={off}
              value={island.flashDuration}
              min={0.5}
              max={5}
              step={0.1}
              caption={seconds(island.flashDuration, 0.5)}
              onChange={(flashDuration) => set({ flashDuration })}
            />
          </Row>
        )}
        <Row title="Statuses" subtitle="Copied text, uploads and saved files." disabled={off}>
          <Switch label="Statuses" checked={island.statuses} disabled={off} onChange={(statuses) => set({ statuses })} />
        </Row>
        <Row title="Animation" disabled={off}>
          <Segmented
            label="Animation"
            disabled={off}
            value={island.animation}
            onChange={(animation) => set({ animation })}
            options={[
              { value: "lively", title: "Lively" },
              { value: "quick", title: "Quick" },
              { value: "none", title: "None" },
            ]}
          />
        </Row>
      </Group>

      <Group title="Panels">
        <PreviewPicker
          popover
          title="Open panels at"
          subtitle="The Cue panel from its shortcut and the tray."
          value={prefs.panels.position}
          options={PANEL_POSITIONS}
          columns={4}
          tileWidth={92}
          onChange={(position) => save({ panels: { ...prefs.panels, position } })}
          preview={(position) => <PanelPositionPreview position={position} />}
        />
        <Row title="Grid columns" subtitle="Cards per row in the Cue panel's grid.">
          <Stepper label="Columns" value={prefs.panels.columns} min={3} max={6} onChange={(columns) => save({ panels: { ...prefs.panels, columns } })} />
        </Row>
      </Group>
    </Pane>
  );
}

/** A screen with the panel where `position` puts it — under the pointer for "Pointer". */
function PanelPositionPreview({ position }: { position: string }) {
  const place: Record<string, React.CSSProperties> = {
    pointer: { left: "30%", top: "34%" },
    top: { left: "30%", top: "8%" },
    center: { left: "30%", top: "30%" },
    bottom: { left: "30%", bottom: "16%" },
    topLeft: { left: "6%", top: "8%" },
    topRight: { right: "6%", top: "8%" },
    bottomLeft: { left: "6%", bottom: "16%" },
    bottomRight: { right: "6%", bottom: "16%" },
  };
  return (
    <span className="position-preview">
      <span className="position-panel" style={place[position]} />
      {position === "pointer" && <span className="position-pointer" />}
      <span className="position-taskbar" />
    </span>
  );
}

// MARK: - Capture

function Capture({ prefs, save }: { prefs: Prefs; save: Save }) {
  return (
    <Pane>
      <Group>
        <Row title="After a capture" subtitle="Either way it is in the island and the Cue panel.">
          <Segmented
            label="After a capture"
            value={prefs.afterCapture}
            onChange={(afterCapture) => save({ afterCapture })}
            options={[
              { value: "edit", title: "Open Editor" },
              { value: "copy", title: "Just Copy" },
            ]}
          />
        </Row>
        <Row title="Copy every capture to the clipboard" subtitle="Paste it anywhere straight away.">
          <Switch label="Copy to the clipboard" checked={prefs.copyToClipboard} onChange={(copyToClipboard) => save({ copyToClipboard })} />
        </Row>
      </Group>

      <Group title="Sound">
        <Row title="Play a sound after each capture" symbol="speaker.wave.2.fill" tint="orange">
          <Switch label="Play a sound" checked={prefs.capture.sound} onChange={(sound) => save({ capture: { ...prefs.capture, sound } })} />
        </Row>
      </Group>

      <Group title="Capture text">
        <Row
          title="Languages"
          subtitle="Cue reads text with Windows' own recognizer, in the languages installed in Windows Settings › Time & language › Language & region."
          symbol="text.viewfinder"
          tint="green"
        >
          <button className="button" onClick={() => ipc.openWindowsSettings("language")}>
            Language Settings…
          </button>
        </Row>
      </Group>
    </Pane>
  );
}

// MARK: - Clipboard

const CLIPBOARD_LIMITS = [50, 100, 200, 500, 1000];

function Clipboard({ prefs, save }: { prefs: Prefs; save: Save }) {
  const [count, setCount] = useState<number | null>(null);
  const load = () => invoke<unknown[]>("store_list", { kind: "clipboard" }).then((list) => setCount(list.length));
  useEffect(() => {
    load();
  }, []);
  useEvent<string>("store-changed", (kind) => kind === "clipboard" && load());
  const set = (patch: Partial<Prefs["clipboard"]>) => save({ clipboard: { ...prefs.clipboard, ...patch } });
  return (
    <Pane>
      <Group>
        <Row title="Keep a clipboard history" subtitle="What you copy shows in the island's Clipboard tab. What password managers mark as private is never kept.">
          <Switch label="Keep a clipboard history" checked={prefs.clipboard.enabled} onChange={(enabled) => set({ enabled })} />
        </Row>
        <Row title="Keep the last" disabled={!prefs.clipboard.enabled}>
          <Select
            label="Keep the last"
            disabled={!prefs.clipboard.enabled}
            value={String(prefs.clipboard.limit)}
            onChange={(v) => set({ limit: Number(v) })}
            options={CLIPBOARD_LIMITS.map((n) => ({ value: String(n), title: `${n} items` }))}
          />
        </Row>
      </Group>
      <Group footer="Pinned items stay. This cannot be undone.">
        <Row title={count === null ? "…" : `${count} item${count === 1 ? "" : "s"} stored`} symbol="doc.on.clipboard" tint="teal">
          <button className="button" disabled={!count} onClick={() => invoke("store_clear_unpinned", { kind: "clipboard" })}>
            Clear History
          </button>
        </Row>
      </Group>
    </Pane>
  );
}

// MARK: - Studio

const STUDIO_DOWNLOAD = "https://github.com/mehedihasanhr/cue-releases/releases";

/** The Mac's Studio pane: whether Cue Studio is here, and what Cue asks it for. */
function Studio({ prefs, save }: { prefs: Prefs; save: Save }) {
  const [state, setState] = useState<{ installed: boolean; path: string | null } | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  useEffect(() => {
    const look = () => invoke<{ installed: boolean; path: string | null }>("studio_state").then(setState);
    look();
    // Installed while this is open: noticed when the window is come back to.
    window.addEventListener("focus", look);
    return () => window.removeEventListener("focus", look);
  }, []);
  const set = (patch: Partial<Prefs["studio"]>) => save({ studio: { ...prefs.studio, ...patch } });
  const run = (command: string) => invoke(command).then(() => setFailure(null)).catch((e) => setFailure(String(e)));
  return (
    <Pane>
      <Group footer={failure ?? undefined}>
        <Row title="Cue Studio" subtitle={state === null ? "…" : state.installed ? "Records the screen with sound, then makes it look made: zooms, a background, a smooth pointer." : "Not installed. Records the screen with sound, then makes it look made."} symbol="record.circle.fill" tint="red">
          {state?.installed ? (
            <span className="row-buttons">
              <button className="button" onClick={() => run("studio_library")}>
                Edit Videos
              </button>
              <button className="button primary" onClick={() => run("studio_record")}>
                Record Screen…
              </button>
            </span>
          ) : (
            <button className="button primary" onClick={() => openUrl(STUDIO_DOWNLOAD)}>
              Download
            </button>
          )}
        </Row>
      </Group>
      <Group title="Recording" disabled={!state?.installed}>
        <Row title="Countdown" subtitle="Seconds before the first frame" symbol="timer" tint="orange">
          <Select label="Countdown" value={String(prefs.studio.countdownSeconds)} onChange={(v) => set({ countdownSeconds: Number(v) })} options={[{ value: "0", title: "None" }, ...[3, 5, 10].map((n) => ({ value: String(n), title: `${n}s` }))]} />
        </Row>
        <Row title="System audio" subtitle="What the PC is playing" symbol="speaker.wave.2.fill" tint="blue">
          <Switch label="System audio" checked={prefs.studio.systemAudio} onChange={(systemAudio) => set({ systemAudio })} />
        </Row>
        <Row title="Microphone" subtitle="Windows may ask for permission the first time" symbol="mic" tint="red">
          <Switch label="Microphone" checked={prefs.studio.microphone} onChange={(microphone) => set({ microphone })} />
        </Row>
        <Row title="Open the editor when a recording stops" symbol="film" tint="purple">
          <Switch label="Open the editor" checked={prefs.studio.opensEditorAfterRecording} onChange={(opensEditorAfterRecording) => set({ opensEditorAfterRecording })} />
        </Row>
      </Group>
    </Pane>
  );
}

// MARK: - Editor

const WEIGHTS: Record<number, string> = { 300: "Light", 400: "Regular", 500: "Medium", 600: "Semibold", 700: "Bold", 800: "Heavy", 900: "Black" };

function Editor({ prefs, save }: { prefs: Prefs; save: Save }) {
  const d = editorDefaults(prefs.editor);
  const set = (patch: Partial<EditorDefaults>) => save({ editor: { ...d, ...patch } });
  const slider = (title: string, key: keyof typeof RANGES, unit: string) => (
    <Row title={title}>
      <Slider
        label={title}
        value={d[key]}
        min={RANGES[key][0]}
        max={RANGES[key][1]}
        step={1}
        width={160}
        captionWidth={66}
        caption={unit ? `{} ${unit}` : "{}"}
        onChange={(value) => set({ [key]: value })}
      />
    </Row>
  );
  return (
    <Pane>
      <Group>
        <Row title="Start each editor with the options last used">
          <Switch label="Remember last used" checked={d.rememberLastUsed} onChange={(rememberLastUsed) => set({ rememberLastUsed })} />
        </Row>
      </Group>

      <Group title="Colors">
        <Row title="Annotations">
          <Swatches color={d.color} onChange={(color) => set({ color })} />
        </Row>
        <Row title="Highlight box">
          <Swatches color={d.highlightColor} onChange={(highlightColor) => set({ highlightColor })} />
        </Row>
      </Group>

      <Group title="Shapes, lines & arrows">
        {slider("Stroke width", "strokeWidth", "px")}
        <Row title="Shape">
          <Segmented
            label="Shape"
            value={d.shapeKind}
            onChange={(shapeKind) => set({ shapeKind })}
            options={[
              { value: "rectangle", title: "Rectangle", symbol: "rectangle" },
              { value: "ellipse", title: "Ellipse", symbol: "oval" },
              { value: "line", title: "Line", symbol: "line.diagonal" },
            ]}
          />
        </Row>
        <Row title="Fill">
          <Segmented
            label="Fill"
            value={d.fill}
            onChange={(fill) => set({ fill })}
            options={[
              { value: "none", title: "None" },
              { value: "solid", title: "Solid" },
              { value: "translucent", title: "Translucent" },
            ]}
          />
        </Row>
        <Row title="Arrow head">
          <Segmented
            label="Arrow head"
            value={d.arrowStyle}
            onChange={(arrowStyle) => set({ arrowStyle })}
            options={[
              { value: "single", title: "One end", symbol: "arrow.right" },
              { value: "double", title: "Both ends", symbol: "arrow.left.and.right" },
            ]}
          />
        </Row>
      </Group>

      <Group title="Text">
        {slider("Font size", "fontSize", "pt")}
        <Row title="Weight">
          <Slider
            label="Weight"
            value={d.fontWeight}
            min={300}
            max={900}
            step={100}
            width={160}
            captionWidth={66}
            caption={WEIGHTS[d.fontWeight] ?? String(d.fontWeight)}
            onChange={(fontWeight) => set({ fontWeight })}
          />
        </Row>
        <Row title="Background">
          <Segmented
            label="Text background"
            value={d.textBackground}
            onChange={(textBackground) => set({ textBackground })}
            options={[
              { value: "none", title: "None" },
              { value: "solid", title: "Solid" },
              { value: "translucent", title: "Translucent" },
            ]}
          />
        </Row>
      </Group>

      <Group title="Marker, blur & counter">
        {slider("Marker width", "highlighterWidth", "px")}
        <Row title="Blur style">
          <Segmented
            label="Blur style"
            value={d.blurKind}
            onChange={(blurKind) => set({ blurKind })}
            options={[
              { value: "blur", title: "Blur" },
              { value: "pixelate", title: "Pixelate" },
            ]}
          />
        </Row>
        {slider("Blur strength", "blurIntensity", "")}
        {slider("Counter size", "counterSize", "px")}
        <Row title="Smart shapes" subtitle="A rough circle, box or arrow drawn with the pencil becomes a neat one.">
          <Switch label="Smart shapes" checked={d.smartShapes} onChange={(smartShapes) => set({ smartShapes })} />
        </Row>
      </Group>

      <Group>
        <Row title="Defaults">
          <button className="button" onClick={() => save({ editor: { ...DEFAULT_PREFS, rememberLastUsed: d.rememberLastUsed } })}>
            Restore Defaults
          </button>
        </Row>
      </Group>
    </Pane>
  );
}

/** The editor's palette, and a colour well for any other. */
function Swatches({ color, onChange }: { color: RGBA; onChange: (color: RGBA) => void }) {
  const same = (a: RGBA, b: RGBA) => Math.abs(a.r - b.r) + Math.abs(a.g - b.g) + Math.abs(a.b - b.b) < 0.01;
  const hex = (c: RGBA) => "#" + [c.r, c.g, c.b].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
  return (
    <span className="swatches">
      {PALETTE.map((swatch) => (
        <button
          key={hex(swatch)}
          className={`swatch ${same(swatch, color) ? "on" : ""}`}
          style={{ background: css(swatch) }}
          aria-label={hex(swatch)}
          aria-pressed={same(swatch, color)}
          onClick={() => onChange(swatch)}
        />
      ))}
      <label className="color-well" title="Other color" style={{ background: css(color) }}>
        <input
          type="color"
          value={hex(color)}
          aria-label="Other color"
          onChange={(e) => {
            const v = e.target.value;
            onChange({ r: parseInt(v.slice(1, 3), 16) / 255, g: parseInt(v.slice(3, 5), 16) / 255, b: parseInt(v.slice(5, 7), 16) / 255 });
          }}
        />
      </label>
    </span>
  );
}
