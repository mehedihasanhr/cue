// The recorder bar — the Mac's `RecorderBar`: a frosted pill at the bottom of the screen.
// Before a take: close · what to record (display, window, area) · what to hear (camera,
// microphone, system audio) · settings · record. Counting down: a ring that drains each
// second. During a take: the time, pause, restart, discard, and stop.

import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useEffect, useRef, useState } from "react";
import { Icon } from "../../../src/ui/icon";
import { clockText, message, studio, type Microphone, type RecordingState, type StartOptions, type Target } from "../lib/ipc";
import { popup } from "../../../src/island/menus";
import "./bar.css";

type Mode = "display" | "window" | "area";
type Chosen = { target: Target; area?: [number, number, number, number] | null; label: string };
type Shape = "setup" | "starting" | "take" | "failure" | "confirmRestart";

const read = (key: string, fallback: string) => {
  try {
    return localStorage.getItem(key) ?? fallback;
  } catch {
    return fallback;
  }
};
const write = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* a convenience */
  }
};

export default function Bar() {
  const [mode, setMode] = useState<Mode>(() => read("studio.mode", "display") as Mode);
  const [chosen, setChosen] = useState<Chosen | null>(null);
  const [systemAudio, setSystemAudio] = useState(() => read("studio.systemAudio", "1") === "1");
  const [microphone, setMicrophone] = useState(() => read("studio.microphone", "0") === "1");
  const [micId, setMicId] = useState<string>(() => read("studio.microphoneId", ""));
  const [mics, setMics] = useState<Microphone[]>([]);
  const [countdown, setCountdown] = useState(() => Number(read("studio.countdown", "3")));
  const [frameRate, setFrameRate] = useState(() => Number(read("studio.frameRate", "60")));
  const [shape, setShape] = useState<Shape>("setup");
  const [remaining, setRemaining] = useState(0);
  const [state, setState] = useState<RecordingState>({ recording: false, paused: false, seconds: 0 });
  const [failure, setFailure] = useState<string | null>(null);
  const counting = useRef<number>(0);
  const lastOptions = useRef<StartOptions | null>(null);

  useEffect(() => {
    getCurrentWindow().show();
    studio.microphones().then(setMics);
    studio.state().then(setState);
  }, []);

  // The time, while a take runs.
  useEffect(() => {
    if (shape !== "take") return;
    const timer = window.setInterval(() => studio.state().then(setState), 250);
    return () => window.clearInterval(timer);
  }, [shape]);

  // A target chosen on one of the overlays.
  useEffect(() => {
    const off = listen<Chosen>("picker:chosen", (e) => {
      setChosen(e.payload);
      studio.closePicker();
      begin(e.payload);
    });
    const cancelled = listen("picker:cancelled", () => studio.closePicker());
    // What Klik asked for (`klik-studio://record`).
    const request = listen<{ target?: Record<string, unknown>; microphone?: boolean; systemAudio?: boolean; countdownSeconds?: number }>(
      "studio:request",
      (e) => {
        const r = e.payload;
        if (r.microphone !== undefined) setMicrophone(r.microphone);
        if (r.systemAudio !== undefined) setSystemAudio(r.systemAudio);
        if (r.countdownSeconds !== undefined) setCountdown(r.countdownSeconds);
        const target = r.target ?? { ask: {} };
        if ("window" in target) chooseMode("window");
        else if ("area" in target) chooseMode("area");
        else chooseMode("display");
      },
    );
    const shortcut = listen<string>("studio:shortcut", (e) => {
      if (e.payload === "toggle") (shape === "take" ? stop() : record());
      else if (e.payload === "pause" && shape === "take") togglePause();
      else if (e.payload === "restart" && shape === "take") restart();
    });
    return () => {
      [off, cancelled, request, shortcut].forEach((p) => p.then((stop) => stop()));
    };
  });

  const save = (key: string, value: string) => write(key, value);

  function chooseMode(next: Mode) {
    setMode(next);
    save("studio.mode", next);
    setChosen(null);
    studio.openPicker(next).catch((e) => fail(message(e)));
  }

  function fail(text: string) {
    setFailure(text);
    setShape("failure");
  }

  /** Record: what was chosen, or the main display when nothing was. */
  async function record() {
    if (chosen) return begin(chosen);
    if (mode === "display") {
      const displays = await studio.displays();
      const main = displays.find((d) => d.primary) ?? displays[0];
      if (!main) return fail("No display to record.");
      return begin({ target: { kind: "display", index: main.index }, label: main.name });
    }
    chooseMode(mode);
  }

  function begin(target: Chosen) {
    const mic = mics.find((m) => m.id === micId);
    const options: StartOptions = {
      target: target.target,
      area: target.area ?? null,
      systemAudio,
      microphone,
      microphoneId: micId || null,
      microphoneName: mic?.name ?? null,
      frameRate,
      quality: "better",
    };
    lastOptions.current = options;
    setFailure(null);
    if (countdown <= 0) return go(options);
    setShape("starting");
    setRemaining(countdown);
    let left = countdown;
    window.clearInterval(counting.current);
    counting.current = window.setInterval(() => {
      left -= 1;
      setRemaining(left);
      if (left <= 0) {
        window.clearInterval(counting.current);
        go(options);
      }
    }, 1000);
  }

  function callOff() {
    window.clearInterval(counting.current);
    setShape("setup");
  }

  async function go(options: StartOptions) {
    try {
      setShape("starting");
      setRemaining(0);
      await studio.start(options);
      setState({ recording: true, paused: false, seconds: 0 });
      setShape("take");
    } catch (e) {
      fail(message(e));
    }
  }

  async function togglePause() {
    if (state.paused) await studio.resume();
    else await studio.pause();
    setState(await studio.state());
  }

  async function stop() {
    setShape("setup");
    try {
      await studio.stop();
    } catch (e) {
      fail(message(e));
    }
    setChosen(null);
  }

  async function discard() {
    await studio.cancel();
    setShape("setup");
  }

  /** Throws the take away and starts again; asks first once there is much to lose. */
  async function restart() {
    if (shape !== "confirmRestart" && state.seconds > 10) {
      if (!state.paused) await studio.pause();
      setShape("confirmRestart");
      return;
    }
    await studio.cancel();
    if (lastOptions.current) go(lastOptions.current);
  }

  async function settingsMenu() {
    await popup([
      { text: "Recordings…", action: () => studio.openLibrary() },
      "-",
      {
        text: "Countdown",
        items: [0, 3, 5, 10].map((n) => ({
          text: n === 0 ? "No countdown" : `${n} seconds`,
          checked: countdown === n,
          action: () => {
            setCountdown(n);
            save("studio.countdown", String(n));
          },
        })),
      },
      {
        text: "Frame rate",
        items: [30, 60].map((n) => ({
          text: `${n} fps`,
          checked: frameRate === n,
          action: () => {
            setFrameRate(n);
            save("studio.frameRate", String(n));
          },
        })),
      },
    ]);
  }

  async function micMenu() {
    await popup([
      { text: "No microphone", checked: !microphone, action: () => { setMicrophone(false); save("studio.microphone", "0"); } },
      "-",
      ...mics.map((m, i) => ({
        text: i === 0 ? `${m.name} (default)` : m.name,
        checked: microphone && (micId === m.id || (!micId && i === 0)),
        action: () => {
          setMicrophone(true);
          setMicId(m.id);
          save("studio.microphone", "1");
          save("studio.microphoneId", m.id);
        },
      })),
    ]);
  }

  return (
    <div className="bar-frame" data-tauri-drag-region>
      <div className={`bar ${shape}`} data-tauri-drag-region>
        {shape === "setup" && (
          <>
            <button className="close-disc" title="Close the recorder" onClick={() => getCurrentWindow().hide()}>
              <Icon name="xmark" size={10} weight={3} />
            </button>
            <span className="separator" />
            <div className="modes" role="radiogroup" aria-label="What to record">
              <ModeButton icon="display" title="Display" on={mode === "display"} onClick={() => chooseMode("display")} />
              <ModeButton icon="macwindow" title="Window" on={mode === "window"} onClick={() => chooseMode("window")} />
              <ModeButton icon="viewfinder" title="Area" on={mode === "area"} onClick={() => chooseMode("area")} />
            </div>
            <span className="separator" />
            <Tile icon="video.slash" title="Camera — coming soon" off disabled />
            <Tile icon={microphone ? "mic" : "mic.slash"} title={microphone ? "Microphone on" : "No microphone"} off={!microphone} onClick={micMenu} />
            <Tile
              icon={systemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill"}
              title={systemAudio ? "System audio on" : "System audio off"}
              off={!systemAudio}
              onClick={() => {
                setSystemAudio(!systemAudio);
                save("studio.systemAudio", systemAudio ? "0" : "1");
              }}
            />
            <span className="separator" />
            <Tile icon="ellipsis" title="Settings" onClick={settingsMenu} />
            <button className="record" title={chosen ? `Record ${chosen.label}` : "Record (Ctrl+Shift+Alt+R)"} onClick={record}>
              <span className="record-dot" />
            </button>
          </>
        )}

        {shape === "starting" && (
          <>
            <div className="countdown" aria-live="polite">
              <svg width="38" height="38" viewBox="0 0 38 38">
                <circle cx="19" cy="19" r="16" className="ring-track" />
                <circle
                  cx="19"
                  cy="19"
                  r="16"
                  className="ring"
                  style={{ strokeDashoffset: `${(1 - remaining / Math.max(1, countdown)) * 100.5}` }}
                />
              </svg>
              <span>{remaining > 0 ? remaining : ""}</span>
            </div>
            <div className="bar-text">
              <div className="bar-title">{remaining > 0 ? "Recording starts…" : "Starting…"}</div>
              <div className="bar-sub">{chosen?.label ?? "Main display"}</div>
            </div>
            <button className="pill" onClick={callOff}>Cancel</button>
          </>
        )}

        {shape === "take" && (
          <>
            <div className="timer">
              <span className={`live-dot ${state.paused ? "held" : ""}`} />
              <span className="time">{clockText(state.seconds)}</span>
              {state.paused && <span className="paused">PAUSED</span>}
            </div>
            <span className="separator" />
            <Tile icon={state.paused ? "play.fill" : "pause.fill"} title={state.paused ? "Resume (Ctrl+Shift+Alt+P)" : "Pause (Ctrl+Shift+Alt+P)"} onClick={togglePause} />
            <Tile icon="arrow.counterclockwise" title="Restart (Ctrl+Shift+Alt+T)" onClick={restart} />
            <Tile icon="trash" title="Discard" onClick={discard} />
            <span className="separator" />
            <button className="stop" title="Stop (Ctrl+Shift+Alt+R)" onClick={stop}>
              <span className="stop-square" />
            </button>
          </>
        )}

        {shape === "confirmRestart" && (
          <>
            <span className="warn">
              <Icon name="arrow.counterclockwise" size={18} />
            </span>
            <div className="bar-text wide">
              <div className="bar-title">Start this take again?</div>
              <div className="bar-sub">The {clockText(state.seconds)} recorded so far will be thrown away.</div>
            </div>
            <button
              className="pill"
              onClick={async () => {
                setShape("take");
                await studio.resume();
              }}
            >
              Keep
            </button>
            <button className="pill danger" onClick={restart}>Restart</button>
          </>
        )}

        {shape === "failure" && (
          <>
            <span className="warn">
              <Icon name="exclamationmark.triangle.fill" size={18} />
            </span>
            <div className="bar-text wide">
              <div className="bar-title">Couldn't record</div>
              <div className="bar-sub">{failure}</div>
            </div>
            <button className="pill" onClick={() => setShape("setup")}>OK</button>
          </>
        )}
      </div>
    </div>
  );
}

function ModeButton({ icon, title, on, onClick }: { icon: "display" | "macwindow" | "viewfinder"; title: string; on: boolean; onClick: () => void }) {
  return (
    <button className={`mode ${on ? "on" : ""}`} role="radio" aria-checked={on} title={title} onClick={onClick}>
      <Icon name={icon} size={18} weight={1.6} />
    </button>
  );
}

function Tile({ icon, title, off, disabled, onClick }: { icon: Parameters<typeof Icon>[0]["name"]; title: string; off?: boolean; disabled?: boolean; onClick?: () => void }) {
  return (
    <button className={`tile ${off ? "off" : ""}`} title={title} aria-label={title} disabled={disabled} onClick={onClick}>
      <Icon name={icon} size={18} weight={1.6} />
    </button>
  );
}

