// One page for every Cue Studio window; the window's label says which one this is:
// `bar`, `picker-N` (the hash is the mode), `library`, `editor-<id>` (the hash is the
// recording's path).

import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import React from "react";
import ReactDOM from "react-dom/client";
import "../../src/styles/base.css";

const label = getCurrentWindow().label;
const hash = decodeURIComponent(window.location.hash.slice(1));

const view = (() => {
  if (label === "bar") {
    const Bar = React.lazy(() => import("./bar/Bar"));
    return <Bar />;
  }
  if (label.startsWith("picker-")) {
    const Picker = React.lazy(() => import("./picker/Picker"));
    const mode = hash === "window" || hash === "area" ? hash : "display";
    return <Picker mode={mode} />;
  }
  if (label === "library") {
    const Library = React.lazy(() => import("./library/Library"));
    return <Library />;
  }
  if (label.startsWith("editor-")) {
    const Editor = React.lazy(() => import("./editor/Editor"));
    const [path, demo] = hash.split("|");
    return <Editor path={path} demo={demo} />;
  }
  return null;
})();

// A failure says what it was, on the page, rather than leaving a blank window.
const show = (text: string) => {
  invoke("log_line", { text }).catch(() => {});
  const pre = document.createElement("pre");
  pre.className = "page-failure";
  pre.textContent = text;
  document.body.appendChild(pre);
};
window.addEventListener("error", (e) => show(`${e.message} at ${e.filename}:${e.lineno}`));
window.addEventListener("unhandledrejection", (e) => show(`Unhandled: ${String(e.reason?.stack ?? e.reason)}`));

ReactDOM.createRoot(document.getElementById("root") as HTMLElement, {
  onUncaughtError: (error) => show(error instanceof Error ? `${error.message}\n${error.stack}` : String(error)),
}).render(<React.Suspense fallback={null}>{view}</React.Suspense>);
