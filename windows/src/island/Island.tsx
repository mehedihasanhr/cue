// The Island, one per display: a black pill at the top centre that opens into the
// panel, and briefly into a capture's flash or a status line. Its geometry and motion
// are the Mac's (`IslandGeometry`, `IslandView`).

import { invoke } from "@tauri-apps/api/core";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useEvent } from "../lib/hooks";
import { ipc, type Settings } from "../lib/ipc";
import { Icon, STROKE, type IconName } from "../ui/icon";
import { Animator, curves, notchPath } from "./motion";
import { Panel } from "./Panel";
import "./island.css";

type Geometry = { pillWidth: number; stripHeight: number; windowWidth: number; windowHeight: number };
type Flash = { url: string; width: number; height: number; copied: boolean; duration: number };
type Status = { symbol: IconName; title: string; subtitle?: string | null; duration: number };

type Phase =
  | { kind: "collapsed" }
  | { kind: "flash"; flash: Flash }
  | { kind: "status"; status: Status }
  | { kind: "expanded" };

// The Mac's measures (IslandGeometry).
const PANEL_WIDTH = 780;
const PANEL_PADDING = { horizontal: 4, bottom: 8 };
const FLASH_HEIGHT = 48;
const OPEN_FLARE = 40;
const CLOSED_FLARE = 6;
const RADIUS = { collapsed: 12, flash: 18, expanded: 34 };
const MIN_FLASH_GROWTH = 40;
const MAX_FLASH_WIDTH = 480;

/** Symbols the island colours, as the Mac's `IslandStatus.tint` does. */
function tint(symbol: string): string {
  if (symbol.includes("checkmark") || symbol.includes("arrow.down.fill")) return "#30d158";
  if (symbol === "tray" || symbol.startsWith("exclamationmark")) return "#ff9f0a";
  return "#ffffff";
}

export default function Island() {
  const [geometry, setGeometry] = useState<Geometry | null>(null);
  const [settings, setSettings] = useState<Settings["island"] | null>(null);
  const [phase, setPhase] = useState<Phase>({ kind: "collapsed" });
  const [faded, setFaded] = useState(true);
  const [contentWidth, setContentWidth] = useState<number | null>(null);
  const [panelHeight, setPanelHeight] = useState(258);
  const [shape, setShape] = useState({ width: 140, height: 22, radius: RADIUS.collapsed, flare: CLOSED_FLARE });
  const animator = useRef<Animator<"width" | "height" | "radius" | "flare"> | null>(null);
  const phaseRef = useRef(phase);
  phaseRef.current = phase;
  const timers = useRef<{ open?: number; close?: number; dismiss?: number; fade?: number }>({});
  const menuOpen = useRef(false);
  const interactive = useRef(false);
  const contentRow = useRef<HTMLDivElement>(null);
  const panelBox = useRef<HTMLDivElement>(null);

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const motion = curves(settings?.animation ?? "lively", reduceMotion);

  // MARK: - Setup

  const loadSettings = () => ipc.getSettings().then((s) => setSettings(s.island));
  useEffect(() => {
    document.documentElement.classList.add("island-root");
    invoke<Geometry>("island_geometry").then((g) => {
      setGeometry(g);
      const start = { width: g.pillWidth, height: g.stripHeight, radius: RADIUS.collapsed, flare: CLOSED_FLARE };
      setShape(start);
      animator.current = new Animator(start, setShape);
      // Shown once drawn, so it never flashes white.
      requestAnimationFrame(() => invoke("island_ready"));
      setTimeout(() => invoke("island_ready"), 300);
    });
    loadSettings();
  }, []);
  useEvent("settings-changed", loadSettings);

  // MARK: - Shape for each phase

  useEffect(() => {
    if (!geometry || !animator.current) return;
    const strip = geometry.stripHeight;
    let target: { width: number; height: number; radius: number; flare: number };
    switch (phase.kind) {
      case "collapsed":
        target = { width: geometry.pillWidth, height: strip, radius: RADIUS.collapsed, flare: CLOSED_FLARE };
        break;
      case "flash":
      case "status": {
        const wanted = contentWidth ?? 340;
        const width = Math.min(Math.max(wanted, geometry.pillWidth + MIN_FLASH_GROWTH), MAX_FLASH_WIDTH);
        target = { width: Math.round(width), height: strip + FLASH_HEIGHT, radius: RADIUS.flash, flare: OPEN_FLARE };
        break;
      }
      case "expanded":
        target = {
          width: PANEL_WIDTH + PANEL_PADDING.horizontal * 2,
          height: strip + Math.min(panelHeight, 330) + PANEL_PADDING.bottom,
          radius: RADIUS.expanded,
          flare: OPEN_FLARE,
        };
        break;
    }
    animator.current.to(target, phase.kind === "collapsed" ? motion.close : motion.open);

    // Closed and settled, the pill fades — unless Settings shows it.
    window.clearTimeout(timers.current.fade);
    if (phase.kind === "collapsed") timers.current.fade = window.setTimeout(() => setFaded(true), 460);
    else setFaded(false);

    setInteractive(phase.kind === "expanded");
  }, [phase.kind, contentWidth, panelHeight, geometry, settings?.animation]);

  function setInteractive(on: boolean) {
    if (interactive.current === on) return;
    interactive.current = on;
    invoke("island_interactive", { interactive: on });
  }

  // Measure what the flash or status row wants, so the shape fits it: a hidden copy at
  // its natural width does the measuring (the Mac's `IdealWidth`), since the visible
  // one stretches to whatever the shape already is.
  useLayoutEffect(() => {
    if ((phase.kind === "flash" || phase.kind === "status") && contentRow.current) {
      setContentWidth(Math.ceil(contentRow.current.getBoundingClientRect().width));
    } else {
      setContentWidth(null);
    }
  }, [phase]);

  useEffect(() => {
    const box = panelBox.current;
    if (!box) return;
    const observer = new ResizeObserver(() => setPanelHeight(box.scrollHeight));
    observer.observe(box);
    return () => observer.disconnect();
  }, [phase.kind]);

  // MARK: - Opening and closing

  function open() {
    window.clearTimeout(timers.current.dismiss);
    window.clearTimeout(timers.current.close);
    setPhase({ kind: "expanded" });
  }

  function close() {
    window.clearTimeout(timers.current.open);
    window.clearTimeout(timers.current.close);
    setPhase({ kind: "collapsed" });
  }

  /** The shape's bounds in the window, in points. */
  function shapeBounds(slop = 0) {
    if (!geometry) return { left: 0, right: 0, bottom: 0 };
    const total = shape.width + shape.flare * 2;
    const left = (geometry.windowWidth - total) / 2;
    return { left: left - slop, right: left + total + slop, bottom: shape.height + slop };
  }

  useEvent<{ x: number; y: number; inWindow: boolean }>("island:pointer", (p) => {
    if (!settings || !geometry) return;
    const current = phaseRef.current;
    const bounds = shapeBounds(current.kind === "collapsed" ? 6 : 0);
    const over = p.inWindow && p.x >= bounds.left && p.x <= bounds.right && p.y <= bounds.bottom;

    if (current.kind === "expanded") {
      if (over || menuOpen.current) {
        window.clearTimeout(timers.current.close);
        timers.current.close = undefined;
      } else if (settings.closeOnLeave && timers.current.close === undefined) {
        timers.current.close = window.setTimeout(close, settings.closeDelay * 1000);
      }
      return;
    }

    if (settings.openMode === "click") {
      // Clicks only reach the page while the pointer is over the pill.
      setInteractive(over);
      return;
    }
    if (over && timers.current.open === undefined) {
      // A flash or a status opens at once under the pointer, as on the Mac.
      const delay = current.kind === "collapsed" ? settings.hoverDelay * 1000 : 0;
      timers.current.open = window.setTimeout(() => {
        timers.current.open = undefined;
        open();
      }, delay);
    } else if (!over && timers.current.open !== undefined) {
      window.clearTimeout(timers.current.open);
      timers.current.open = undefined;
    }
  });

  function dismissAfter(seconds: number) {
    window.clearTimeout(timers.current.dismiss);
    timers.current.dismiss = window.setTimeout(() => {
      if (phaseRef.current.kind === "flash" || phaseRef.current.kind === "status") setPhase({ kind: "collapsed" });
    }, seconds * 1000);
  }

  useEvent<Flash>("island:flash", (flash) => {
    if (phaseRef.current.kind === "expanded") return;
    setPhase({ kind: "flash", flash });
    dismissAfter(flash.duration);
  });

  const showStatus = (status: Status) => {
    if (phaseRef.current.kind === "expanded") return;
    setPhase({ kind: "status", status });
    dismissAfter(status.duration || 1.8);
  };
  useEvent<Status>("island:status", showStatus);

  // Debug builds: `--island-demo <phase>` shows a phase without the pointer.
  useEvent<string>("island:demo", (name) => {
    if (name === "expanded") open();
    else if (name === "flash") setPhase({ kind: "flash", flash: { url: "", width: 1920, height: 1080, copied: true, duration: 60 } });
    else if (name === "status") setPhase({ kind: "status", status: { symbol: "checkmark.circle.fill", title: "Text copied", subtitle: "3 lines on the clipboard", duration: 60 } });
    else close();
  });

  // Esc closes; clicking outside the shape, inside the window, does too.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && phaseRef.current.kind === "expanded") close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  if (!geometry || !settings) return null;

  const total = shape.width + shape.flare * 2;
  const left = (geometry.windowWidth - total) / 2;
  const path = notchPath(shape.width, shape.height, shape.flare, shape.radius);
  const collapsed = phase.kind === "collapsed";
  const black = !(collapsed && faded && !settings.showPill);
  const rim = phase.kind === "expanded";

  return (
    <div
      className="island-window"
      onMouseDown={(e) => {
        const b = shapeBounds();
        const inside = e.clientX >= b.left && e.clientX <= b.right && e.clientY <= b.bottom;
        if (!inside && phase.kind === "expanded") close();
        else if (inside && collapsed && settings.openMode === "click") open();
      }}
    >
      <svg className="island-shape" width={geometry.windowWidth} height={geometry.windowHeight} aria-hidden>
        <defs>
          <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#fff" stopOpacity="0" />
            <stop offset="0.5" stopColor="#fff" stopOpacity="0.05" />
            <stop offset="1" stopColor="#fff" stopOpacity="0.16" />
          </linearGradient>
        </defs>
        <g transform={`translate(${left} 0)`}>
          <path d={path} fill={black ? "#000" : "transparent"} className={black ? "" : "faded"} />
          <path d={path} fill="none" stroke="url(#rim)" strokeWidth={1} opacity={rim ? 1 : 0} className="rim" />
        </g>
      </svg>

      <div
        className="island-content"
        style={{ left, width: total, height: shape.height, clipPath: `path("${path}")` }}
      >
        <div className="island-body" style={{ marginLeft: shape.flare, width: shape.width, paddingTop: geometry.stripHeight }}>
          {(phase.kind === "flash" || phase.kind === "status") && (
            <>
              <div className="island-row" key={phase.kind === "flash" ? phase.flash.url : phase.status.title}>
                {phase.kind === "flash" ? <FlashRow flash={phase.flash} /> : <StatusRow status={phase.status} />}
              </div>
              <div className="island-measure" ref={contentRow} aria-hidden>
                {phase.kind === "flash" ? <FlashRow flash={phase.flash} /> : <StatusRow status={phase.status} />}
              </div>
            </>
          )}
          {phase.kind === "expanded" && (
            <div
              className="island-panel"
              ref={panelBox}
              style={{ padding: `0 ${PANEL_PADDING.horizontal}px ${PANEL_PADDING.bottom}px` }}
            >
              <Panel
                mode="island"
                initialTab={settings.opensOn}
                onWantsKeyboard={() => invoke("island_take_keyboard")}
                onMenu={(open) => (menuOpen.current = open)}
                onDone={close}
                onStatus={(title, symbol, subtitle) => {
                  close();
                  setTimeout(() => showStatus({ title, symbol, subtitle, duration: 1.8 }), 120);
                }}
              />
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

/** "Just captured": the thumbnail and a copied confirmation (the Mac's `FlashRow`). */
function FlashRow({ flash }: { flash: Flash }) {
  return (
    <div className="flash-row">
      <img src={flash.url} alt="" className="flash-thumb" />
      <div className="row-text">
        <div className="row-title">{flash.copied ? "Copied to clipboard" : "Saved to History"}</div>
        <div className="row-subtitle">{flash.width} × {flash.height}</div>
      </div>
      <span className="row-spacer" />
      <span style={{ color: "#30d158" }}>
        <Icon name="checkmark.circle.fill" size={21} weight={STROKE.semibold} />
      </span>
    </div>
  );
}

function StatusRow({ status }: { status: Status }) {
  return (
    <div className="flash-row">
      <div className="row-text">
        <div className="row-title">{status.title}</div>
        {status.subtitle && <div className="row-subtitle">{status.subtitle}</div>}
      </div>
      <span className="row-spacer" />
      <span style={{ color: tint(status.symbol) }}>
        <Icon name={status.symbol} size={21} weight={STROKE.semibold} />
      </span>
    </div>
  );
}
