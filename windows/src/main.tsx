import { getCurrentWindow } from "@tauri-apps/api/window";
import React from "react";
import ReactDOM from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import "./styles/base.css";

// Script errors go to the app's log, where they can be found without developer tools.
const report = (text: string) => invoke("log_error", { textValue: text }).catch(() => {});
window.addEventListener("error", (e) => report(`${e.message} at ${e.filename}:${e.lineno}`));
window.addEventListener("unhandledrejection", (e) => report(`Unhandled: ${String(e.reason?.message ?? e.reason)}`));

// One page for every window; the window's label says which one this is.
const label = getCurrentWindow().label;

const view = (() => {
  if (label.startsWith("overlay-")) {
    const Overlay = React.lazy(() => import("./overlay/Overlay"));
    return <Overlay index={Number(label.slice("overlay-".length))} />;
  }
  if (label.startsWith("editor-")) {
    const Editor = React.lazy(() => import("./editor/Editor"));
    return <Editor id={label.slice("editor-".length)} />;
  }
  if (label.startsWith("island-")) {
    const Island = React.lazy(() => import("./island/Island"));
    return <Island />;
  }
  if (label === "panel") {
    const CuePanel = React.lazy(() => import("./island/CuePanel"));
    return <CuePanel />;
  }
  if (label.startsWith("pin-")) {
    const Pin = React.lazy(() => import("./pin/Pin"));
    return <Pin id={label.slice("pin-".length)} />;
  }
  if (label === "settings") {
    const Settings = React.lazy(() => import("./settings/Settings"));
    return <Settings />;
  }
  return null;
})();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement, {
  onUncaughtError: (error) => report(`Render: ${error instanceof Error ? `${error.message}\n${error.stack}` : String(error)}`),
}).render(
  <React.StrictMode>
    <React.Suspense fallback={null}>{view}</React.Suspense>
  </React.StrictMode>,
);
