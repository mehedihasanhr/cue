// The edit's state: the timeline, undo and redo (whole snapshots, as the Mac's
// `UndoStack`), and saving to `project.json` a moment after each change.

import { useCallback, useEffect, useRef, useState } from "react";
import { studio } from "../lib/ipc";
import { writeTimeline, type Timeline } from "./model/timeline";

const clone = (t: Timeline): Timeline => structuredClone(t);
const LIMIT = 200;

export type Commit = (change: (t: Timeline) => void | boolean, coalesce?: string) => void;

export function useEdit(path: string, initial: Timeline, saveNow: boolean) {
  const [timeline, setTimeline] = useState(initial);
  const undo = useRef<Timeline[]>([]);
  const redo = useRef<Timeline[]>([]);
  const last = useRef<{ key: string; at: number } | null>(null);
  const [, bump] = useState(0);
  const [saveError, setSaveError] = useState<string | null>(null);

  const current = useRef(timeline);
  current.current = timeline;

  /** Applies a change to a copy; returning false calls it off. Slider drags coalesce. */
  const commit: Commit = useCallback((change, coalesce) => {
    const before = current.current;
    const next = clone(before);
    if (change(next) === false) return;
    const now = performance.now();
    const same = coalesce && last.current && last.current.key === coalesce && now - last.current.at < 800;
    if (!same) {
      undo.current.push(before);
      if (undo.current.length > LIMIT) undo.current.shift();
      redo.current = [];
    }
    last.current = coalesce ? { key: coalesce, at: now } : null;
    current.current = next;
    setTimeline(next);
  }, []);

  const undoLast = useCallback(() => {
    const previous = undo.current.pop();
    if (!previous) return;
    redo.current.push(current.current);
    last.current = null;
    current.current = previous;
    setTimeline(previous);
    bump((n) => n + 1);
  }, []);

  const redoLast = useCallback(() => {
    const next = redo.current.pop();
    if (!next) return;
    undo.current.push(current.current);
    last.current = null;
    current.current = next;
    setTimeline(next);
    bump((n) => n + 1);
  }, []);

  // Saved shortly after each change, and once at the start for a new edit.
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      if (!saveNow) return;
    }
    const timer = window.setTimeout(() => {
      studio
        .writeProject(path, writeTimeline(timeline))
        .then(() => setSaveError(null))
        .catch((e) => setSaveError(String(e)));
    }, 500);
    return () => window.clearTimeout(timer);
  }, [timeline, path, saveNow]);

  return { timeline, commit, undo: undoLast, redo: redoLast, canUndo: undo.current.length > 0, canRedo: redo.current.length > 0, saveError };
}
