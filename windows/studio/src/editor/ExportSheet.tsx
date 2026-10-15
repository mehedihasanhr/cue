// Export — the Mac's `ExportSheet`: size, frame rate and quality (first time: "Send" —
// 1920 on the long side, 60 fps, better), where to save, then the progress.

import { save } from "@tauri-apps/plugin-dialog";
import { useRef, useState } from "react";
import { Segmented, Select } from "../../../src/settings/controls";
import { message, studio } from "../lib/ipc";
import { duration as editLength } from "./model/clips";
import type { Timeline } from "./model/timeline";
import type { Scene } from "./render/scene";
import { bitrate, exportSize, exportVideo, SEND, type ExportSettings, type Progress, type Quality } from "./export/export";

const KEY = "studio.export";

function remembered(): ExportSettings {
  try {
    return { ...SEND, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") };
  } catch {
    return SEND;
  }
}

type Props = { packagePath: string; name: string; timeline: Timeline; scene: Scene; onClose: () => void };

export default function ExportSheet({ packagePath, name, timeline, scene, onClose }: Props) {
  const [settings, setSettings] = useState(remembered);
  const [progress, setProgress] = useState<Progress | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  const abort = useRef<AbortController | null>(null);

  const project = scene.outputSize(timeline.style);
  const size = exportSize(project, settings.maxSide);
  const length = editLength(timeline);
  const megabytes = Math.round(((bitrate(size.width, size.height, settings.fps, settings.quality) + 192000) * length) / 8 / 1e6);

  const change = (patch: Partial<ExportSettings>) => {
    const next = { ...settings, ...patch };
    setSettings(next);
    try {
      localStorage.setItem(KEY, JSON.stringify(next));
    } catch {
      /* a convenience */
    }
  };

  const start = async () => {
    const output = await save({ defaultPath: `${name}.mp4`, filters: [{ name: "MPEG-4 video", extensions: ["mp4"] }] });
    if (!output) return;
    setFailure(null);
    setDone(null);
    const controller = new AbortController();
    abort.current = controller;
    setProgress({ phase: "sound", fraction: 0 });
    const sound = timeline.sound.isMuted ? [] : timeline.soundTracks.filter((s) => !s.style.isMuted).map((s) => ({ path: s.path, gain: s.style.gain * timeline.sound.gain }));
    try {
      await exportVideo({ packagePath, timeline, scene, sound, output, settings, onProgress: setProgress, signal: controller.signal });
      setDone(output);
    } catch (e) {
      if ((e as Error)?.name !== "AbortError") setFailure(message(e));
    } finally {
      setProgress(null);
      abort.current = null;
    }
  };

  const percent = progress ? Math.round((progress.phase === "sound" ? 0.02 : progress.phase === "finishing" ? 0.99 : 0.03 + progress.fraction * 0.96) * 100) : 0;

  return (
    <div className="sheet-backdrop" onPointerDown={(e) => e.target === e.currentTarget && !progress && onClose()}>
      <div className="sheet" role="dialog" aria-label="Export">
        <h2>Export</h2>
        {done ? (
          <>
            <p className="sheet-text">Saved as {done.split(/[\\/]/).pop()}.</p>
            <div className="sheet-actions">
              <button className="sheet-button" onClick={() => studio.reveal(done)}>
                Show in Explorer
              </button>
              <button className="sheet-button" onClick={() => studio.openFile(done)}>
                Play
              </button>
              <button className="sheet-button primary" onClick={onClose}>
                Done
              </button>
            </div>
          </>
        ) : progress ? (
          <>
            <p className="sheet-text">{progress.phase === "sound" ? "Mixing the sound…" : progress.phase === "finishing" ? "Finishing…" : "Exporting…"}</p>
            <div className="progress">
              <span style={{ width: `${percent}%` }} />
            </div>
            <div className="sheet-actions">
              <span className="sheet-meta">{percent}%</span>
              <button className="sheet-button" onClick={() => abort.current?.abort()}>
                Cancel
              </button>
            </div>
          </>
        ) : (
          <>
            <div className="sheet-row">
              <span>Size</span>
              <Select
                label="Size"
                width={200}
                value={String(settings.maxSide ?? "project")}
                onChange={(v) => change({ maxSide: v === "project" ? null : Number(v) })}
                options={[
                  { value: "project", title: `As edited (${project.width} × ${project.height})` },
                  { value: "3840", title: "4K (3840)" },
                  { value: "2560", title: "1440p (2560)" },
                  { value: "1920", title: "1080p (1920)" },
                  { value: "1280", title: "720p (1280)" },
                ]}
              />
            </div>
            <div className="sheet-row">
              <span>Frame rate</span>
              <Segmented label="Frame rate" value={settings.fps} options={[{ value: 30, title: "30 fps" }, { value: 60, title: "60 fps" }]} onChange={(v) => change({ fps: v as 30 | 60 })} />
            </div>
            <div className="sheet-row">
              <span>Quality</span>
              <Segmented<Quality>
                label="Quality"
                value={settings.quality}
                options={[{ value: "smaller", title: "Smaller" }, { value: "good", title: "Good" }, { value: "better", title: "Better" }, { value: "best", title: "Best" }]}
                onChange={(v) => change({ quality: v })}
              />
            </div>
            <p className="sheet-meta">
              MP4 · {size.width} × {size.height} · about {megabytes < 1 ? "1" : megabytes} MB
            </p>
            {failure && <p className="sheet-error">{failure}</p>}
            <div className="sheet-actions">
              <button className="sheet-button" onClick={onClose}>
                Cancel
              </button>
              <button className="sheet-button primary" onClick={start}>
                Export…
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
