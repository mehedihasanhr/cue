// The editor — the Mac's `EditorView`: a slim title strip; then the tool rail, the picture
// with the transport and the timeline under it, and the inspector with Export at its head.
// One window per recording; the package's path is the window's hash.

import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Icon } from "../../../src/ui/icon";
import { clockText, fileUrl, message, studio, type ProjectFiles } from "../lib/ipc";
import ExportSheet from "./ExportSheet";
import { exportVideo } from "./export/export";
import Inspector, { TOOLS, type Tool } from "./Inspector";
import { deleteClip, duration as editLength, split } from "./model/clips";
import { CursorTrack } from "./model/cursor";
import { placedOnTimeline, suggestClickZooms } from "./model/suggest";
import { newTimeline, readTimeline, uuid, type SoundTrack, type Timeline } from "./model/timeline";
import Preview, { type PreviewHandle } from "./Preview";
import { Scene, type Artwork } from "./render/scene";
import TimelineStrip, { addZoomAt, type Selection } from "./TimelineStrip";
import { useEdit } from "./useEdit";
import "../../../src/settings/settings.css";
import "./editor.css";

type Loaded = { files: ProjectFiles; timeline: Timeline; scene: Scene; track: CursorTrack; isNew: boolean };

export default function Editor({ path, demo }: { path: string; demo?: string }) {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  useEffect(() => {
    load(path)
      .then(setLoaded)
      .catch((e) => setFailure(message(e)))
      .finally(() => getCurrentWindow().show());
  }, [path]);

  if (failure) {
    return (
      <div className="editor-failure">
        <Icon name="exclamationmark.triangle" size={28} />
        <p>{failure}</p>
      </div>
    );
  }
  if (!loaded) return <div className="studio-editor loading" />;
  return <Loaded {...loaded} path={path} demo={demo} />;
}

async function load(path: string): Promise<Loaded> {
  const files = await studio.readProject(path);
  const m = files.manifest;
  const screen = m.tracks.find((t) => t.kind === "screen");
  if (!screen?.pixelSize) throw new Error("This recording has no picture.");
  const [w, h] = screen.pixelSize;
  const sounds: SoundTrack[] = m.tracks
    .filter((t) => t.kind === "systemAudio" || t.kind === "microphone")
    .map((t) => ({ id: uuid(), source: t.kind as SoundTrack["source"], name: t.name ?? "", path: t.path, deviceID: t.deviceID, style: { isMuted: false, gain: 1, cleansVoice: false, evensVolume: false } }));

  const track = CursorTrack.parse(files.cursor, files.input);
  const isNew = files.project === null;
  const timeline = isNew ? newTimeline(m.duration, sounds) : readTimeline(files.project, m.duration, sounds);
  if (isNew) {
    // An area take: its area is the crop.
    const r = files.pendingCrop?.rect;
    if (r) timeline.style.crop = { x: r[0][0], y: r[0][1], width: r[1][0], height: r[1][1] };
    // Zooms on the clicks, as the Mac does on a recording's first opening.
    const points = { width: w / m.displayScale, height: h / m.displayScale };
    const crop = timeline.style.crop ?? { x: 0, y: 0, width: 1, height: 1 };
    timeline.zooms = placedOnTimeline(timeline, suggestClickZooms(track.clicks, points, crop, m.duration));
  }

  const artwork: Record<string, Artwork> = {};
  for (const [shape, a] of Object.entries(files.cursorArtwork ?? {})) {
    const image = new Image();
    image.src = fileUrl(path, a.path);
    artwork[shape] = { image, aspect: a.height / Math.max(1, a.width), hotspotX: a.hotspotX, hotspotY: a.hotspotY };
  }
  let background: HTMLImageElement | null = null;
  const scene = new Scene(w, h, m.displayScale, track.isEmpty ? null : track, artwork, () => {
    const b = loadedTimeline?.style.background;
    if (b?.kind !== "image") return null;
    if (!background || background.dataset.path !== b.path) {
      background = new Image();
      background.dataset.path = b.path;
      background.src = fileUrl(path, b.path);
    }
    return background.complete && background.naturalWidth ? background : null;
  });
  return { files, timeline, scene, track, isNew };
}

/** The timeline the scene's background lookup reads; set by the open editor. */
let loadedTimeline: Timeline | null = null;

function Loaded({ files, timeline: initial, scene, track, isNew, path, demo }: Loaded & { path: string; demo?: string }) {
  const { timeline, commit, undo, redo, canUndo, canRedo, saveError } = useEdit(path, initial, isNew);
  loadedTimeline = timeline;
  const [time, setTime] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [tool, setTool] = useState<Tool>("frame");
  const [selection, setSelection] = useState<Selection>(null);
  const [exporting, setExporting] = useState(false);
  const preview = useRef<PreviewHandle>(null);
  const length = editLength(timeline);
  const name = files.manifest.name;

  // A debug build's `--demo`: `t=<seconds>`, `select=zoom|clip`, `tool=<tool>`, `export=<file>`.
  useEffect(() => {
    if (!demo) return;
    const spec = Object.fromEntries(demo.split(";").map((p) => p.split("=") as [string, string]));
    if (spec.t) setTime(Number(spec.t));
    if (spec.tool) setTool(spec.tool as Tool);
    if (spec.select === "zoom" && timeline.zooms[0]) setSelection({ kind: "zoom", id: timeline.zooms[0].id });
    if (spec.select === "clip") setSelection({ kind: "clip", index: 0 });
    if (spec.export) {
      const sound = timeline.soundTracks.map((s) => ({ path: s.path, gain: s.style.gain }));
      const began = performance.now();
      let lastProgress = "";
      // On top while it runs: an engine may hold back a window nobody can see.
      getCurrentWindow().setAlwaysOnTop(true).catch(() => {});
      exportVideo({ packagePath: path, timeline, scene, sound, output: spec.export, settings: { maxSide: 1920, fps: 30, quality: "better" }, onProgress: (p) => {
          const key = `${p.phase} ${Math.floor(p.fraction * 10)}`;
          if (key !== lastProgress) invoke("log_line", { text: `demo: ${(lastProgress = key)}` });
        }, signal: new AbortController().signal })
        .finally(() => getCurrentWindow().setAlwaysOnTop(false).catch(() => {}))
        .then(() => invoke("log_line", { text: `demo: exported in ${Math.round(performance.now() - began)} ms` }))
        .catch((e) => invoke("log_line", { text: `demo: export failed: ${message(e)}` }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // A selection that has gone (undone, deleted) is let go of.
  useEffect(() => {
    if (selection?.kind === "zoom" && !timeline.zooms.some((z) => z.id === selection.id)) setSelection(null);
    if (selection?.kind === "clip" && !timeline.clips[selection.index]) setSelection(null);
    if (time > length) setTime(length);
  }, [timeline, selection, time, length]);

  const seek = useCallback((t: number) => {
    preview.current?.pause();
    setTime(t);
  }, []);

  const togglePlay = () => (playing ? preview.current?.pause() : preview.current?.play());

  const splitHere = () => {
    commit((t) => split(t, time));
  };

  const addZoom = () => {
    const id = addZoomAt(commit, timeline, time);
    if (id) setSelection({ kind: "zoom", id });
  };

  const autoZoom = () => {
    const pts = { width: scene.videoWidth / scene.displayScale, height: scene.videoHeight / scene.displayScale };
    const crop = timeline.style.crop ?? { x: 0, y: 0, width: 1, height: 1 };
    commit((t) => {
      const suggested = placedOnTimeline(t, suggestClickZooms(track.clicks, pts, crop, t.sourceDuration));
      const kept = t.zooms.filter((z) => z.source !== "click" || z.isEdited);
      const free = suggested.filter((s) => !kept.some((k) => s.start < k.start + k.duration && k.start < s.start + s.duration));
      t.zooms = [...kept, ...free].sort((a, b) => a.start - b.start);
    });
  };

  const deleteSelection = () => {
    if (selection?.kind === "zoom") commit((t) => void (t.zooms = t.zooms.filter((z) => z.id !== selection.id)));
    else if (selection?.kind === "clip") commit((t) => deleteClip(t, selection.index));
    setSelection(null);
  };

  // The keyboard, as the Mac's editor.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      if (target.closest("input, textarea, select") && e.key !== "Escape") return;
      if (exporting) return;
      const ctrl = e.ctrlKey || e.metaKey;
      const step = e.shiftKey ? 1 : 1 / 60;
      if (e.key === " ") togglePlay();
      else if (ctrl && e.key.toLowerCase() === "z") e.shiftKey ? redo() : undo();
      else if (ctrl && e.key.toLowerCase() === "y") redo();
      else if (ctrl && e.key.toLowerCase() === "e") setExporting(true);
      else if ((ctrl && e.key.toLowerCase() === "b") || (!ctrl && e.key.toLowerCase() === "s")) splitHere();
      else if (!ctrl && e.key.toLowerCase() === "z") addZoom();
      else if (e.key === "Delete" || e.key === "Backspace") deleteSelection();
      else if (e.key === "ArrowLeft") seek(Math.max(0, time - step));
      else if (e.key === "ArrowRight") seek(Math.min(length, time + step));
      else if (e.key === "Home") seek(0);
      else if (e.key === "End") seek(length);
      else if (e.key === "Escape") setSelection(null);
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const sounds = useMemo(
    () => (timeline.sound.isMuted ? [] : timeline.soundTracks.filter((s) => !s.style.isMuted).map((s) => ({ url: fileUrl(path, s.path), gain: s.style.gain * timeline.sound.gain }))),
    [timeline.sound, timeline.soundTracks, path],
  );

  const editing = selection?.kind === "zoom" ? selection : tool === "crop" && !selection ? ({ kind: "crop" } as const) : null;
  const clip = selection?.kind === "clip" ? timeline.clips[selection.index] : undefined;

  return (
    <div className="studio-editor">
      <header className="title-strip" data-tauri-drag-region>
        <span className="title-name" data-tauri-drag-region>
          {name}
        </span>
        {saveError && <span className="save-error" title={saveError}>Not saved</span>}
        <span className="title-actions">
          <button className="glyph" title="Undo (Ctrl+Z)" disabled={!canUndo} onClick={undo}>
            <Icon name="arrow.uturn.backward" size={15} />
          </button>
          <button className="glyph" title="Redo (Ctrl+Shift+Z)" disabled={!canRedo} onClick={redo}>
            <Icon name="arrow.uturn.forward" size={15} />
          </button>
          <button className="glyph" title="Show in Explorer" onClick={() => studio.reveal(path)}>
            <Icon name="folder" size={15} />
          </button>
          <button className="glyph" title="Recordings" onClick={() => studio.openLibrary()}>
            <Icon name="square.grid.2x2" size={15} />
          </button>
        </span>
      </header>

      <div className="editor-columns">
        <nav className="rail">
          {TOOLS.map((t) => (
            <button
              key={t.id}
              className={`rail-tab ${tool === t.id && !selection ? "on" : ""}`}
              title={t.title}
              onClick={() => {
                setTool(t.id);
                setSelection(null);
              }}
            >
              <Icon name={t.symbol} size={18} />
              <span>{t.title}</span>
            </button>
          ))}
        </nav>

        <main className="middle">
          <Preview
            scene={scene}
            timeline={timeline}
            time={time}
            playing={playing}
            videoUrl={fileUrl(path, "media/screen.mp4")}
            sounds={sounds}
            editing={editing}
            commit={commit}
            onTime={setTime}
            onPlaying={setPlaying}
            handle={preview}
          />
          <div className="transport">
            <span className="timecode">
              {clockText(time)}
              <em> / {clockText(length)}</em>
            </span>
            <span className="transport-middle">
              <button className="glyph" title="To the start (Home)" onClick={() => seek(0)}>
                <Icon name="arrow.counterclockwise" size={15} />
              </button>
              <button className="play" title="Play (Space)" onClick={togglePlay}>
                <Icon name={playing ? "pause.fill" : "play.fill"} size={16} />
              </button>
            </span>
            <span className="transport-tools">
              <button className="pill" title="Split at the playhead (S)" onClick={splitHere}>
                <Icon name="scissors" size={14} /> Split
              </button>
              <button className="pill" title="Add a zoom at the playhead (Z)" onClick={addZoom}>
                <Icon name="plus.magnifyingglass" size={14} /> Zoom
              </button>
              {clip && <span className="pill quiet">{clip.speed}×</span>}
            </span>
          </div>
          <TimelineStrip timeline={timeline} time={time} selection={selection} onSelect={setSelection} onSeek={seek} commit={commit} />
        </main>

        <Inspector
          timeline={timeline}
          tool={tool}
          selection={selection}
          commit={commit}
          onExport={() => {
            preview.current?.pause();
            setExporting(true);
          }}
          onAutoZoom={autoZoom}
          onDeleteSelection={deleteSelection}
          hasClicks={track.clicks.length > 0}
        />
      </div>

      {exporting && <ExportSheet packagePath={path} name={name} timeline={timeline} scene={scene} onClose={() => setExporting(false)} />}
    </div>
  );
}
