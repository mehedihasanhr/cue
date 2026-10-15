// The capture editor: annotate, crop and frame a capture, then copy or save it.

import { ask, save } from "@tauri-apps/plugin-dialog";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { useCallback, useEffect, useRef, useState } from "react";
import { useAppearance, useShowWhenReady, useToast } from "../lib/hooks";
import { ipc, message, type HistoryItem } from "../lib/ipc";
import { DEFAULT_BACKGROUND, type Doc } from "./model/document";
import type { Annotation } from "./model/types";
import { edgeColor, encode, renderToCanvas, type Source } from "./render";
import { loadPrefs, savePrefs, TOOL_KEYS, type Prefs, type Tool } from "./prefs";
import { Stage, type StageHandle } from "./Stage";
import { BackgroundPanel, OptionsBar, StatusBar, Toolbar } from "./Toolbar";
import "./editor.css";

type History = { past: Doc[]; present: Doc; future: Doc[] };

export default function Editor({ id }: { id: string }) {
  useAppearance();
  const [item, setItem] = useState<HistoryItem | null>(null);
  const [source, setSource] = useState<Source | null>(null);
  const [history, setHistory] = useState<History | null>(null);
  const [saved, setSaved] = useState<Doc | null>(null);
  const [tool, setTool] = useState<Tool>("arrow");
  const [prefs, setPrefsState] = useState<Prefs>(() => loadPrefs(null));
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showBackground, setShowBackground] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [busy, setBusy] = useState(false);
  const [toast, showToast] = useToast();
  const stage = useRef<StageHandle>(null);

  const doc = history?.present ?? null;
  const dirty = !!doc && doc !== saved;

  // MARK: - Loading

  useEffect(() => {
    ipc.getSettings().then((settings) => setPrefsState(loadPrefs(settings.editor)));
  }, []);

  useEffect(() => {
    ipc
      .historyItem(id)
      .then((value) => {
        setItem(value);
        getCurrentWindow().setTitle(`${value.fileName.replace(/\.png$/i, "")} — Klik`);
        const image = new Image();
        image.crossOrigin = "anonymous";
        image.onload = () => {
          const first: Doc = {
            width: image.naturalWidth / value.scale,
            height: image.naturalHeight / value.scale,
            scale: value.scale,
            annotations: [],
            crop: null,
            background: null,
            nextCounter: 1,
          };
          setSource({ image, edgeColor: edgeColor(image) });
          setHistory({ past: [], present: first, future: [] });
          setSaved(first);
        };
        image.src = `${value.url}?t=${Date.now()}`;
      })
      .catch(() => getCurrentWindow().destroy());
  }, [id]);
  useShowWhenReady(!!source);

  const setPrefs = (patch: Partial<Prefs>) =>
    setPrefsState((p) => {
      const next = { ...p, ...patch };
      savePrefs(next);
      return next;
    });

  // MARK: - Undo

  // A run of changes to the same thing — a slider being dragged — is one undo step.
  const lastCoalesce = useRef<{ key: string; at: number } | null>(null);
  const commit = useCallback((next: Doc, coalesce?: string) => {
    const now = Date.now();
    const merge = !!coalesce && lastCoalesce.current?.key === coalesce && now - lastCoalesce.current.at < 800;
    lastCoalesce.current = coalesce ? { key: coalesce, at: now } : null;
    setHistory((h) => {
      if (!h) return h;
      if (merge) return { ...h, present: next, future: [] };
      return { past: [...h.past, h.present].slice(-100), present: next, future: [] };
    });
  }, []);

  const undo = () =>
    setHistory((h) => (h && h.past.length ? { past: h.past.slice(0, -1), present: h.past[h.past.length - 1], future: [h.present, ...h.future] } : h));
  const redo = () =>
    setHistory((h) => (h && h.future.length ? { past: [...h.past, h.present], present: h.future[0], future: h.future.slice(1) } : h));

  // MARK: - Editing the selection with the toolbar

  /** Applies a style change to the selected annotation too, as the Mac's inspector does. */
  function restyle(patch: Partial<Prefs>) {
    setPrefs(patch);
    if (!doc || !selectedId) return;
    const annotations = doc.annotations.map((a) => {
      if (a.id !== selectedId) return a;
      const color = patch.color;
      switch (a.type) {
        case "rectangle": case "ellipse":
          return { ...a, style: { stroke: { color: color ?? a.style.stroke.color, width: patch.strokeWidth ?? a.style.stroke.width }, fill: patch.fill ?? a.style.fill } };
        case "line": case "pencil":
          return { ...a, style: { color: color ?? a.style.color, width: patch.strokeWidth ?? a.style.width } };
        case "arrow":
          return { ...a, style: { color: color ?? a.style.color, width: patch.strokeWidth ?? a.style.width }, arrowStyle: patch.arrowStyle ?? a.arrowStyle };
        case "highlighter":
          return { ...a, style: { color: patch.highlightColor ?? a.style.color, width: patch.highlighterWidth ?? a.style.width } };
        case "highlight":
          return { ...a, color: patch.highlightColor ?? a.color };
        case "text":
          return { ...a, style: { ...a.style, color: color ?? a.style.color, fontSize: patch.fontSize ?? a.style.fontSize, weight: patch.fontWeight ?? a.style.weight, background: patch.textBackground ?? a.style.background } };
        case "counter":
          return { ...a, color: color ?? a.color, size: patch.counterSize ?? a.size };
        case "blur":
          return { ...a, kind: patch.blurKind ?? a.kind, intensity: patch.blurIntensity ?? a.intensity };
      }
    });
    commit({ ...doc, annotations }, `style:${selectedId}:${Object.keys(patch).join()}`);
  }

  function deleteSelected() {
    if (!doc || !selectedId) return;
    commit({ ...doc, annotations: doc.annotations.filter((a) => a.id !== selectedId) });
    setSelectedId(null);
  }

  /** A copy of the selection, a little down and to the right, selected. */
  function duplicateSelected() {
    const original = doc?.annotations.find((a) => a.id === selectedId);
    if (!doc || !original) return;
    const copy = shifted({ ...structuredClone(original), id: crypto.randomUUID() }, 12);
    commit({ ...doc, annotations: [...doc.annotations, copy] });
    setSelectedId(copy.id);
  }

  function applyCrop() {
    if (!doc || !stage.current) return;
    const r = stage.current.cropRect();
    const whole = r.x <= 0 && r.y <= 0 && r.width >= doc.width - 0.5 && r.height >= doc.height - 0.5;
    if (r.width >= 2 && r.height >= 2) commit({ ...doc, crop: whole ? null : r });
    setTool("select");
  }

  function toggleBackground() {
    if (!doc) return;
    if (doc.background) {
      setShowBackground((shown) => !shown);
    } else {
      commit({ ...doc, background: DEFAULT_BACKGROUND });
      setShowBackground(true);
    }
  }

  // MARK: - Output

  async function rendered(type: "image/png" | "image/jpeg" = "image/png") {
    return encode(renderToCanvas(doc!, source!), type);
  }

  async function run(work: () => Promise<void>) {
    if (busy || !doc || !source) return;
    setBusy(true);
    try {
      await work();
    } catch (error) {
      showToast(message(error));
    } finally {
      setBusy(false);
    }
  }

  const copy = () => run(async () => {
    await ipc.editorCopy(await rendered());
    showToast("Copied");
  });

  const saveOver = (quiet = false) => run(async () => {
    await ipc.editorSave(id, await rendered());
    setSaved(doc);
    if (!quiet) showToast("Saved");
  });

  const saveAs = () => run(async () => {
    const name = item?.fileName.replace(/\.png$/i, "") ?? "Screenshot";
    const path = await save({
      defaultPath: `${name}.png`,
      filters: [{ name: "PNG", extensions: ["png"] }, { name: "JPEG", extensions: ["jpg", "jpeg"] }],
    });
    if (!path) return;
    const jpeg = /\.jpe?g$/i.test(path);
    await ipc.editorWriteFile(path, await rendered(jpeg ? "image/jpeg" : "image/png"));
    showToast("Saved a copy");
  });

  const deleteCapture = async () => {
    const sure = await ask("Delete this capture? It goes to the Recycle Bin.", {
      title: "Klik", kind: "warning", okLabel: "Delete", cancelLabel: "Cancel",
    });
    if (!sure) return;
    run(async () => {
      await ipc.historyDelete(id);
      await getCurrentWindow().destroy();
    });
  };

  const done = () => run(async () => {
    if (dirty) await ipc.editorSave(id, await rendered());
    await getCurrentWindow().destroy();
  });

  // Closing with changes asks first: saving flattens them into the capture for good.
  useEffect(() => {
    const window = getCurrentWindow();
    const off = window.onCloseRequested(async (event) => {
      if (!dirty) return;
      event.preventDefault();
      const keep = await ask("Save your changes to this capture?", {
        title: "Klik", kind: "info", okLabel: "Save", cancelLabel: "Don't Save",
      });
      if (keep && doc && source) await ipc.editorSave(id, await encode(renderToCanvas(doc, source), "image/png")).catch(() => {});
      await window.destroy();
    });
    return () => {
      off.then((stop) => stop());
    };
  }, [dirty, doc, source]);

  // MARK: - Keyboard

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement) return;
      const key = e.key.toLowerCase();
      if (e.ctrlKey) {
        if (key === "z" && !e.shiftKey) undo();
        else if ((key === "z" && e.shiftKey) || key === "y") redo();
        else if (key === "c") copy();
        else if (key === "d") duplicateSelected();
        else if (key === "s" && e.shiftKey) saveAs();
        else if (key === "s") saveOver();
        else if (key === "0") stage.current?.fit();
        else if (key === "1") stage.current?.actualSize();
        else if (key === "=" || key === "+") stage.current?.zoomBy(1.25);
        else if (key === "-") stage.current?.zoomBy(0.8);
        else return;
        e.preventDefault();
        return;
      }
      if (key === "delete" || key === "backspace") deleteSelected();
      else if (key === "escape") tool === "crop" ? setTool("select") : setSelectedId(null);
      else if (key === "enter" && tool === "crop") applyCrop();
      else if (key === "g") toggleBackground();
      else if (TOOL_KEYS[key]) setTool(TOOL_KEYS[key]);
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  if (!doc || !source) return null;
  const selected = doc.annotations.find((a) => a.id === selectedId) ?? null;

  const showOptions = tool !== "select" || !!selected;
  const out = { width: (doc.crop?.width ?? doc.width) * doc.scale, height: (doc.crop?.height ?? doc.height) * doc.scale };

  return (
    <div className="editor">
      <Toolbar
        tool={tool}
        onTool={(t) => {
          setTool(t);
          if (t !== "select") setSelectedId(null);
        }}
        prefs={prefs}
        onStyle={restyle}
        backgroundOpen={showBackground}
        onBackground={toggleBackground}
        canUndo={history!.past.length > 0}
        canRedo={history!.future.length > 0}
        onUndo={undo}
        onRedo={redo}
        busy={busy}
        onCopy={copy}
        onExport={saveAs}
        onDelete={deleteCapture}
        onDone={done}
      />
      {showOptions && (
        <OptionsBar
          tool={tool}
          prefs={prefs}
          selected={selected}
          onStyle={restyle}
          onDuplicate={duplicateSelected}
          onDeleteSelected={deleteSelected}
          onApplyCrop={applyCrop}
          onResetCrop={() => {
            commit({ ...doc, crop: null });
            setTool("select");
          }}
        />
      )}
      <div className="editor-body">
        {showBackground && doc.background && (
          <BackgroundPanel
            background={doc.background}
            onChange={(background) => commit({ ...doc, background }, "background")}
            onRemove={() => {
              commit({ ...doc, background: null });
              setShowBackground(false);
            }}
            onClose={() => setShowBackground(false)}
          />
        )}
        <Stage
          ref={stage}
          doc={doc}
          source={source}
          tool={tool}
          prefs={prefs}
          selectedId={selectedId}
          onSelect={setSelectedId}
          onCommit={commit}
          onZoomChange={setZoom}
        />
      </div>
      <StatusBar
        pixelWidth={Math.round(out.width)}
        pixelHeight={Math.round(out.height)}
        scale={doc.scale}
        cropped={!!doc.crop}
        zoom={zoom * (window.devicePixelRatio || 1) / doc.scale}
        onZoomOut={() => stage.current?.zoomBy(0.8)}
        onZoomIn={() => stage.current?.zoomBy(1.25)}
        onActualSize={() => stage.current?.actualSize()}
        onFit={() => stage.current?.fit()}
      />
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  );
}

/** `annotation` moved by `d` points both ways. */
function shifted(annotation: Annotation, d: number): Annotation {
  const p = (q: { x: number; y: number }) => ({ x: q.x + d, y: q.y + d });
  const r = (q: { x: number; y: number; width: number; height: number }) => ({ ...q, x: q.x + d, y: q.y + d });
  switch (annotation.type) {
    case "rectangle": case "ellipse": case "highlight": case "blur": return { ...annotation, rect: r(annotation.rect) };
    case "line": return { ...annotation, start: p(annotation.start), end: p(annotation.end) };
    case "arrow": return { ...annotation, start: p(annotation.start), end: p(annotation.end) };
    case "pencil": case "highlighter": return { ...annotation, points: annotation.points.map(p) };
    case "text": return { ...annotation, origin: p(annotation.origin) };
    case "counter": return { ...annotation, center: p(annotation.center) };
  }
}
