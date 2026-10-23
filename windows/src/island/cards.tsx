// The island's cards, one per kind — the Mac's `CaptureCard`, `ClipboardCard`,
// `AssetCard`, `ColorCard`, `SnippetCard`, `NoteCard`, `AnswerCard` and the search's
// `TaskCard` — on one frame: 156 × 124, radius 14, the hover row of round buttons on top
// and the caption at the bottom.

import { useState, type ReactNode } from "react";
import type { HistoryItem } from "../lib/ipc";
import { Icon, STROKE, type IconName } from "../ui/icon";
import type { QuickAnswer } from "./answers";
import { cssColor, format, FORMAT_TITLES, inSRGB, isLight, type ColorFormat } from "./colormath";
import {
  byteSize,
  firstLine,
  cueUrl,
  NEXT_STATUS,
  PRIORITY_COLORS,
  PRIORITY_SYMBOLS,
  STATUS_COLORS,
  STATUS_TITLES,
  summary,
  timeOf,
  type Asset,
  type ClipItem,
  type ColorItem,
  type Note,
  type Snippet,
  type TaskItem,
} from "./data";
import { relative } from "./answers";

export const CARD = { width: 156, height: 124 };

// MARK: - Frame

type Frame = {
  title?: string;
  onClick?: (e: React.MouseEvent) => void;
  onContextMenu?: (e: React.MouseEvent) => void;
  onHover?: (over: boolean) => void;
  selected?: boolean;
  picked?: number | null;
  /** The hover row: round buttons at the left, one more at the right. */
  actions?: ReactNode;
  trailing?: ReactNode;
  caption?: ReactNode;
  className?: string;
  style?: React.CSSProperties;
  copied?: boolean;
  children: ReactNode;
};

export function CardFrame(p: Frame) {
  return (
    <div
      className={`card ${p.className ?? ""} ${p.selected ? "selected" : ""} ${p.picked ? "picked" : ""}`}
      style={p.style}
      title={p.title}
      onClick={p.onClick}
      onContextMenu={p.onContextMenu}
      onMouseEnter={() => p.onHover?.(true)}
      onMouseLeave={() => p.onHover?.(false)}
    >
      {p.children}
      {p.caption && <div className="caption">{p.caption}</div>}
      {(p.actions || p.trailing) && (
        <div className="card-actions" onClick={(e) => e.stopPropagation()}>
          {p.actions}
          <span className="spacer" />
          {p.trailing}
        </div>
      )}
      {p.picked ? <span className="pick-badge">{p.picked}</span> : null}
      {p.copied && (
        <div className="card-copied">
          <Icon name="checkmark.circle.fill" size={26} weight={STROKE.semibold} />
          Copied
        </div>
      )}
    </div>
  );
}

export function CardAction({ symbol, help, tint, onClick }: { symbol: IconName; help: string; tint?: string; onClick: () => void }) {
  return (
    <button className="card-action" title={help} aria-label={help} style={tint ? { color: tint } : undefined} onClick={onClick}>
      <Icon name={symbol} size={13} weight={STROKE.bold} />
    </button>
  );
}

/** Copy that turns into a green tick for a moment. */
export function CopyAction({ onCopy }: { onCopy: () => void }) {
  const [done, setDone] = useState(false);
  return (
    <CardAction
      symbol={done ? "checkmark" : "doc.on.doc"}
      help="Copy"
      tint={done ? "#30d158" : undefined}
      onClick={() => {
        onCopy();
        setDone(true);
        setTimeout(() => setDone(false), 1200);
      }}
    />
  );
}

function PinMark({ pinned }: { pinned?: boolean }) {
  return pinned ? (
    <span className="pinned">
      <Icon name="pin.fill" size={10} />
    </span>
  ) : null;
}

export function Caption({ title, line, pinned, badge }: { title?: ReactNode; line?: ReactNode; pinned?: boolean; badge?: ReactNode }) {
  return (
    <>
      {title && <div className="caption-title">{title}</div>}
      <div className="caption-line">
        <span className="caption-sub">{line}</span>
        <span className="spacer" />
        <PinMark pinned={pinned} />
        {badge && <span className="badge">{badge}</span>}
      </div>
    </>
  );
}

// MARK: - Captures

export const captureTitle = (item: HistoryItem) => item.fileName.replace(/\.png$/i, "");
export const isDefaultName = (item: HistoryItem) => /^Screenshot \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \(\d+\))?$/.test(captureTitle(item));

export function CaptureCardBody({ item, version }: { item: HistoryItem; version: number }) {
  return <img className="card-image" src={`${item.thumbnailUrl}?v=${version}`} alt="" draggable={false} loading="lazy" />;
}

export function captureCaption(item: HistoryItem, renaming?: ReactNode) {
  return (
    <Caption
      title={renaming ?? (!isDefaultName(item) ? captureTitle(item) : undefined)}
      line={timeOf(item.createdAt)}
      pinned={item.pinned}
      badge={`${item.pixelWidth} × ${item.pixelHeight}`}
    />
  );
}

// MARK: - Clipboard

/** A guess at the language of copied code, or null for prose. */
export function detectCode(text: string): string | null {
  const t = text.trim();
  if (t.length < 12) return null;
  if ((t.startsWith("{") && t.endsWith("}")) || (t.startsWith("[") && t.endsWith("]"))) {
    try {
      JSON.parse(t);
      return "JSON";
    } catch {
      /* not JSON */
    }
  }
  const rules: [string, RegExp][] = [
    ["HTML", /^\s*<(!doctype|html|div|span|p|a|section|body|head|ul|li|script|style)\b/i],
    ["SQL", /^\s*(select|insert|update|delete|create|alter|with)\s.+\s(from|into|table|set|as)\b/is],
    ["Swift", /\b(func|let|var|guard|struct|enum)\s+\w+.*(->|:\s*\w+|\{)/],
    ["Rust", /\b(fn|let mut|impl|pub fn|use \w+::)\b/],
    ["Python", /^\s*(def |class |import |from \w+ import |if __name__)/m],
    ["TypeScript", /\b(interface|type)\s+\w+\s*=?\s*\{|:\s*(string|number|boolean)\b/],
    ["JavaScript", /\b(const|let|function|=>|import .+ from|export (default|const|function))\b/],
    ["CSS", /^[\s\S]*[.#]?[\w-]+\s*\{[^}]*:[^}]*;[^}]*\}/],
    ["Shell", /^\s*(\$ |sudo |npm |pnpm |yarn |git |cd |ls |curl |brew |cargo )/m],
    ["PowerShell", /^\s*(Get-|Set-|New-|\$env:)/m],
  ];
  for (const [name, pattern] of rules) if (pattern.test(t)) return name;
  const codeish = (t.match(/[{};=()<>]/g) ?? []).length / t.length;
  return codeish > 0.06 && t.includes("\n") ? "Code" : null;
}

export function ClipCardBody({ item }: { item: ClipItem }) {
  const text = item.text ?? "";
  switch (item.kind) {
    case "image":
      return <img className="card-image" src={cueUrl(`clip/${item.id}`)} alt="" draggable={false} loading="lazy" />;
    case "color":
      return <div className="card-fill" style={{ background: text }}><span className="color-chip">{text}</span></div>;
    case "link": {
      let host = text;
      try {
        host = new URL(text).host || text;
      } catch {
        /* keep the text */
      }
      return (
        <div className="card-text">
          <div className="link-host">{host.replace(/^www\./, "")}</div>
          <div className="link-url">{text}</div>
        </div>
      );
    }
    case "files": {
      const files = text.split("\n").filter(Boolean);
      return (
        <div className="card-text">
          <div className="link-host">
            <Icon name="doc" size={13} /> {files.length === 1 ? "File" : `${files.length} files`}
          </div>
          {files.slice(0, 4).map((f) => (
            <div key={f} className="file-name">{f.split(/[\\/]/).pop()}</div>
          ))}
        </div>
      );
    }
    default: {
      const language = detectCode(text);
      return language ? (
        <div className="card-text code"><pre>{text.slice(0, 600)}</pre></div>
      ) : (
        <div className="card-text"><div className="text-preview">{text.slice(0, 600)}</div></div>
      );
    }
  }
}

export function clipCaption(item: ClipItem) {
  const text = item.text ?? "";
  const language = item.kind === "text" ? detectCode(text) : null;
  const badge =
    item.kind === "image" && item.pixelWidth
      ? `${item.pixelWidth} × ${item.pixelHeight}`
      : language
        ? `${language} · ${text.split("\n").length} lines`
        : undefined;
  const when = relative(new Date(item.createdAt));
  return <Caption title={item.name} line={item.sourceName ? `${when} · ${item.sourceName}` : when} pinned={item.pinned} badge={badge} />;
}

// MARK: - Assets

export function AssetCardBody({ item }: { item: Asset }) {
  if (item.kind === "image") return <img className="card-image" src={cueUrl(`asset/${item.id}`)} alt="" draggable={false} loading="lazy" />;
  const ext = item.fileName.includes(".") ? item.fileName.split(".").pop()!.toUpperCase() : "FILE";
  return (
    <div className="card-file">
      <Icon name="doc" size={40} weight={1.2} />
      <span className="file-ext">{ext}</span>
    </div>
  );
}

export function assetCaption(item: Asset) {
  return (
    <Caption
      title={item.fileName}
      pinned={item.pinned}
      badge={item.kind === "image" && item.pixelWidth ? `${item.pixelWidth} × ${item.pixelHeight}` : byteSize(item.byteSize)}
    />
  );
}

// MARK: - Colors

export function ColorCardBody({ item }: { item: ColorItem }) {
  return (
    <div className="card-fill" style={{ background: cssColor(item.color), color: isLight(item.color) ? "#000" : "#fff" }}>
      {!inSRGB(item.color) && <span className="p3-chip">P3</span>}
    </div>
  );
}

export function colorCaption(item: ColorItem, preferred: ColorFormat) {
  const value = format(item.color, preferred);
  // Named, the name leads and the value follows; the HEX badge shows when the value
  // shown isn't HEX already, as on the Mac.
  const showHex = !!item.name || preferred !== "hex";
  const line = item.name && preferred !== "hex" ? value : undefined;
  return <Caption title={item.name ?? value} line={line ?? (preferred === "hex" ? undefined : FORMAT_TITLES[preferred])} pinned={item.pinned} badge={showHex ? format(item.color, "hex") : undefined} />;
}

// MARK: - Snippets

export function SnippetCardBody({ item }: { item: Snippet }) {
  const blanks = [...new Set([...item.text.matchAll(/\{\{\s*([^}]+?)\s*\}\}/g)].map((m) => m[1]))];
  return (
    <div className="card-text snippet">
      <div className="snippet-head">
        <span className="keyword">{item.keyword}</span>
        {item.name && <span className="snippet-name">{item.name}</span>}
      </div>
      {item.assetID ? (
        <img className="snippet-asset" src={cueUrl(`asset/${item.assetID}`)} alt="" />
      ) : (
        <div className="text-preview small">{item.text}</div>
      )}
      {blanks.length > 0 && (
        <div className="blank-chips">
          {blanks.slice(0, 3).map((b) => (
            <span key={b} className="blank-chip">{b}</span>
          ))}
        </div>
      )}
    </div>
  );
}

export function snippetCaption(item: Snippet) {
  const blanks = new Set([...item.text.matchAll(/\{\{\s*([^}]+?)\s*\}\}/g)].map((m) => m[1])).size;
  const uses = item.uses === 0 ? "Not used yet" : item.uses === 1 ? "Used once" : `Used ${item.uses} times`;
  return <Caption line={uses} badge={blanks ? `${blanks} blank${blanks === 1 ? "" : "s"}` : undefined} />;
}

// MARK: - Notes

export function NoteCardBody({ item }: { item: Note }) {
  return (
    <div className="card-text note">
      <div className="note-title">{firstLine(item.text) || "Untitled"}</div>
      <div className="text-preview small">{summary(item.text)}</div>
    </div>
  );
}

export function noteCaption(item: Note) {
  return <Caption line={`Note · ${relative(new Date(item.updatedAt))}`} />;
}

// MARK: - Answers

export function AnswerCardBody({ answer }: { answer: QuickAnswer }) {
  return (
    <div className="card-text answer">
      {answer.color && <div className="answer-swatch" style={{ background: cssColor(answer.color) }} />}
      <div className="answer-label">
        <Icon name={answer.symbol} size={11} /> {answer.label}
      </div>
      <div className="answer-value">{answer.value}</div>
    </div>
  );
}

// MARK: - Tasks (in search results)

export function TaskCardBody({ item, project }: { item: TaskItem; project?: string }) {
  return (
    <div className="card-text task">
      <div className="task-status" style={{ color: STATUS_COLORS[item.status] }}>
        <Icon name={item.status === "complete" ? "checkmark.circle.fill" : "circle"} size={12} weight={STROKE.semibold} /> {STATUS_TITLES[item.status]}
      </div>
      <div className="note-title">{firstLine(item.text)}</div>
      <div className="task-meta">
        <span style={{ color: PRIORITY_COLORS[item.priority] }}>
          <Icon name={PRIORITY_SYMBOLS[item.priority]} size={10} weight={STROKE.bold} />
        </span>
        {project && <span className="project-pill">{project}</span>}
      </div>
    </div>
  );
}

export const nextStatusTitle = (item: TaskItem) => `Mark ${STATUS_TITLES[NEXT_STATUS[item.status]].toLowerCase()}`;
