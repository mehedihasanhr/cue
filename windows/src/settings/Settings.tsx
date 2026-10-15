// Settings: what happens after a capture, where captures go, the shortcuts, and about.

import { getVersion } from "@tauri-apps/api/app";
import { relaunch } from "@tauri-apps/plugin-process";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { open } from "@tauri-apps/plugin-dialog";
import { useEffect, useState } from "react";
import { useAppearance, useShowWhenReady } from "../lib/hooks";
import { ipc, message, type Conflict, type Settings as Prefs } from "../lib/ipc";
import { display, fromEvent } from "./accelerator";
import "./settings.css";

type Section = "general" | "shortcuts" | "sharing" | "about";

const ACTIONS: { id: string; title: string }[] = [
  { id: "captureArea", title: "Capture area" },
  { id: "captureWindow", title: "Capture window" },
  { id: "captureFullScreen", title: "Capture full screen" },
  { id: "captureText", title: "Capture text" },
  { id: "showHistory", title: "Open History" },
];

export default function Settings() {
  useAppearance();
  const [prefs, setPrefs] = useState<Prefs | null>(null);
  const [autostart, setAutostart] = useState(false);
  const [defaultFolder, setDefaultFolder] = useState("");
  const [conflicts, setConflicts] = useState<Conflict[]>([]);
  const [section, setSection] = useState<Section>("general");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([ipc.getSettings(), ipc.getAutostart(), ipc.defaultFolder(), ipc.shortcutConflicts()]).then(
      ([p, a, f, c]) => {
        setPrefs(p);
        setAutostart(a);
        setDefaultFolder(f);
        setConflicts(c);
      },
    );
  }, []);
  useShowWhenReady(prefs !== null);

  if (!prefs) return null;

  const save = (next: Prefs) => {
    setPrefs(next);
    ipc.setSettings(next).then(setConflicts).catch((e) => setError(message(e)));
  };

  return (
    <div className="settings">
      <nav className="settings-nav" aria-label="Settings">
        {(["general", "shortcuts", "sharing", "about"] as Section[]).map((id) => (
          <button key={id} className={section === id ? "active" : ""} onClick={() => setSection(id)}>
            {id[0].toUpperCase() + id.slice(1)}
          </button>
        ))}
      </nav>
      <main className="settings-page">
        {error && <div className="banner" role="alert">{error}</div>}

        {section === "general" && (
          <>
            <h1>General</h1>
            <Group title="Startup">
              <Row title="Open Klik when you sign in" detail="It waits in the tray, ready for its shortcuts.">
                <Toggle
                  checked={autostart}
                  onChange={(on) => {
                    setAutostart(on);
                    ipc.setAutostart(on).catch((e) => setError(message(e)));
                  }}
                />
              </Row>
            </Group>
            <Group title="After a capture">
              <Row title="Then" detail="Every capture is also kept in History.">
                <select
                  value={prefs.afterCapture}
                  onChange={(e) => save({ ...prefs, afterCapture: e.target.value as Prefs["afterCapture"] })}
                >
                  <option value="edit">Open the editor</option>
                  <option value="copy">Just copy it</option>
                </select>
              </Row>
              <Row title="Copy to the clipboard" detail="Paste it anywhere straight away.">
                <Toggle checked={prefs.copyToClipboard} onChange={(on) => save({ ...prefs, copyToClipboard: on })} />
              </Row>
            </Group>
            <Group title="Captures folder">
              <Row title={prefs.saveFolder ?? defaultFolder} detail={prefs.saveFolder ? "Chosen by you" : "The default"}>
                <div className="row-buttons">
                  <button
                    className="button"
                    onClick={async () => {
                      const folder = await open({ directory: true, defaultPath: prefs.saveFolder ?? defaultFolder });
                      if (typeof folder === "string") save({ ...prefs, saveFolder: folder });
                    }}
                  >
                    Choose…
                  </button>
                  {prefs.saveFolder && (
                    <button className="button" onClick={() => save({ ...prefs, saveFolder: null })}>Use default</button>
                  )}
                  <button className="button" onClick={() => ipc.historyOpenFolder()}>Open</button>
                </div>
              </Row>
            </Group>
            <Group title="Appearance">
              <Row title="Theme">
                <select
                  value={prefs.appearance}
                  onChange={(e) => save({ ...prefs, appearance: e.target.value as Prefs["appearance"] })}
                >
                  <option value="system">Match Windows</option>
                  <option value="light">Light</option>
                  <option value="dark">Dark</option>
                </select>
              </Row>
            </Group>
          </>
        )}

        {section === "shortcuts" && (
          <>
            <h1>Shortcuts</h1>
            <p className="lead">They work in every app. Click one and press the new keys; Backspace clears it.</p>
            <Group title="Global shortcuts">
              {ACTIONS.map((action) => {
                const conflict = conflicts.find((c) => c.action === action.id);
                return (
                  <Row
                    key={action.id}
                    title={action.title}
                    detail={conflict ? "Another app is using this one. Pick different keys." : undefined}
                    warning={!!conflict}
                  >
                    <ShortcutField
                      value={prefs.shortcuts[action.id] ?? ""}
                      onChange={(value) => save({ ...prefs, shortcuts: { ...prefs.shortcuts, [action.id]: value } })}
                    />
                  </Row>
                );
              })}
            </Group>
            <p className="note">
              To use Print Screen, first turn off <em>Use the Print screen key to open screen capture</em> in Windows
              Settings › Accessibility › Keyboard.
            </p>
          </>
        )}

        {section === "sharing" && <Sharing prefs={prefs} save={save} />}
        {section === "about" && <About />}
      </main>
    </div>
  );
}

function Sharing({ prefs, save }: { prefs: Prefs; save: (p: Prefs) => void }) {
  const share = prefs.share;
  const [secrets, setSecrets] = useState<Record<string, boolean>>({});
  const set = (patch: Partial<Prefs["share"]>) => save({ ...prefs, share: { ...share, ...patch } });
  useEffect(() => {
    ipc.shareSecretStatus().then(setSecrets);
  }, []);

  const text = (title: string, key: keyof Prefs["share"], placeholder = "", detail?: string) => (
    <Row title={title} detail={detail}>
      <input
        className="field"
        defaultValue={share[key] as string}
        placeholder={placeholder}
        spellCheck={false}
        onBlur={(e) => e.target.value !== share[key] && set({ [key]: e.target.value.trim() })}
      />
    </Row>
  );

  const secret = (title: string, name: string) => (
    <Row title={title} detail={secrets[name] ? "Saved in Windows Credential Manager" : "Not set"}>
      <input
        className="field"
        type="password"
        placeholder={secrets[name] ? "••••••••" : ""}
        onBlur={(e) => {
          if (!e.target.value) return;
          ipc.setShareSecret(name, e.target.value).then(() => {
            e.target.value = "";
            ipc.shareSecretStatus().then(setSecrets);
          });
        }}
      />
    </Row>
  );

  return (
    <>
      <h1>Sharing</h1>
      <p className="lead">Copy Share Link in History uploads a capture and puts its link on the clipboard.</p>
      <Group title="Upload to">
        <Row title="Service">
          <select value={share.provider} onChange={(e) => set({ provider: e.target.value as Prefs["share"]["provider"] })}>
            <option value="off">Off</option>
            <option value="s3">S3-compatible bucket</option>
            <option value="custom">Custom endpoint</option>
          </select>
        </Row>
        <Row title="Name uploads by date" detail="Off: a short random name, harder to guess.">
          <Toggle checked={share.datedNames} onChange={(on) => set({ datedNames: on })} />
        </Row>
      </Group>
      {share.provider === "s3" && (
        <Group title="Bucket">
          {text("Endpoint", "endpoint", "s3.us-east-1.amazonaws.com", "AWS S3, Cloudflare R2, MinIO, Backblaze B2…")}
          {text("Region", "region", "auto")}
          {text("Bucket", "bucket")}
          {text("Folder", "prefix", "klik/")}
          {text("Access key", "accessKey")}
          {secret("Secret key", "share.s3.secretKey")}
          {text("Public URL", "publicBase", "https://cdn.example.com", "Optional: what goes before the file name in the link.")}
        </Group>
      )}
      {share.provider === "custom" && (
        <Group title="Endpoint">
          {text("URL", "customUrl", "https://example.com/upload/{name}", "{name} is replaced by the file name.")}
          <Row title="Method" detail="PUT sends the PNG; POST sends it as a form field named “file”.">
            <select value={share.customMethod} onChange={(e) => set({ customMethod: e.target.value as "PUT" | "POST" })}>
              <option value="PUT">PUT</option>
              <option value="POST">POST</option>
            </select>
          </Row>
          {text("Header", "customHeaderName", "Authorization")}
          {secret("Header value", "share.custom.headerValue")}
          {text("Link in the answer", "customResponseKey", "url", "For a JSON answer, where the link is, e.g. data.link.")}
        </Group>
      )}
    </>
  );
}

function About() {
  const [version, setVersion] = useState("");
  const [update, setUpdate] = useState<Update | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  useEffect(() => {
    getVersion().then(setVersion);
  }, []);

  async function checkForUpdates() {
    setWorking(true);
    setStatus("Checking…");
    try {
      const found = await check();
      setUpdate(found);
      setStatus(found ? `Klik ${found.version} is available.` : "You have the newest version.");
    } catch (error) {
      setStatus(`Couldn't check: ${message(error)}`);
    } finally {
      setWorking(false);
    }
  }

  async function install() {
    if (!update) return;
    setWorking(true);
    let total = 0;
    let received = 0;
    try {
      await update.downloadAndInstall((event) => {
        if (event.event === "Started") total = event.data.contentLength ?? 0;
        if (event.event === "Progress") {
          received += event.data.chunkLength;
          if (total) setStatus(`Downloading… ${Math.round((received / total) * 100)}%`);
        }
        if (event.event === "Finished") setStatus("Installing…");
      });
      await relaunch();
    } catch (error) {
      setStatus(`Couldn't install: ${message(error)}`);
      setWorking(false);
    }
  }

  return (
    <>
      <h1>About</h1>
      <Group title="Klik for Windows">
        <Row title="Version" detail={version} />
        <Row title="Updates" detail={status ?? "Klik checks a little after it starts."}>
          {update ? (
            <button className="button primary" disabled={working} onClick={install}>Install and Restart</button>
          ) : (
            <button className="button" disabled={working} onClick={checkForUpdates}>Check for Updates</button>
          )}
        </Row>
        <Row title="Privacy" detail="Captures stay on this PC.">
          <a className="button" href="https://mehedihasanhr.github.io/klik/privacy/" target="_blank" rel="noreferrer">
            Privacy Policy
          </a>
        </Row>
      </Group>
    </>
  );
}

function Group({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="group">
      <h2>{title}</h2>
      <div className="group-body">{children}</div>
    </section>
  );
}

function Row(props: { title: string; detail?: string; warning?: boolean; children?: React.ReactNode }) {
  return (
    <div className="row">
      <div className="row-text">
        <div className="row-title">{props.title}</div>
        {props.detail && <div className={`row-detail ${props.warning ? "warning" : ""}`}>{props.detail}</div>}
      </div>
      {props.children}
    </div>
  );
}

function Toggle({ checked, onChange }: { checked: boolean; onChange: (on: boolean) => void }) {
  return (
    <button role="switch" aria-checked={checked} className={`toggle ${checked ? "on" : ""}`} onClick={() => onChange(!checked)}>
      <span />
    </button>
  );
}

function ShortcutField({ value, onChange }: { value: string; onChange: (value: string) => void }) {
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
      className={`shortcut ${recording ? "recording" : ""}`}
      onClick={() => setRecording(!recording)}
      onBlur={() => setRecording(false)}
      aria-label={recording ? "Press the new shortcut" : `Shortcut ${value || "none"}`}
    >
      {recording ? <span className="hint">Press keys…</span> : value ? display(value).map((k) => <kbd key={k}>{k}</kbd>) : <span className="hint">None</span>}
    </button>
  );
}
