// A card opened in place — the Mac's `IslandDetail`: a ‹ Back pill and what the item
// is, then the item large with its actions. ← → move to the neighbouring cards.

import type { ReactNode } from "react";
import type { HistoryItem } from "../lib/ipc";
import { Icon, STROKE, type IconName } from "../ui/icon";
import { relative } from "./answers";
import { captureTitle, detectCode } from "./cards";
import { cssColor, format, FORMAT_TITLES, FORMATS, type ColorFormat } from "./colormath";
import { byteSize, firstLine, cueUrl, type Asset, type ClipItem, type ColorItem, type Note, type Snippet } from "./data";

export type DetailItem =
  | { kind: "captures"; item: HistoryItem }
  | { kind: "clipboard"; item: ClipItem }
  | { kind: "assets"; item: Asset }
  | { kind: "colors"; item: ColorItem }
  | { kind: "snippets"; item: Snippet }
  | { kind: "notes"; item: Note };

export type DetailButton = { title: string; symbol: IconName; onClick: () => void; tint?: string };

type Props = {
  entry: DetailItem;
  version: number;
  buttons: DetailButton[];
  colorFormat: ColorFormat;
  onCopyText: (text: string, format?: ColorFormat) => void;
  onBack: () => void;
  onRevealPath?: (path: string) => void;
};

export function Detail({ entry, version, buttons, colorFormat, onCopyText, onBack, onRevealPath }: Props) {
  const pills: string[] = [];
  let body: ReactNode = null;

  switch (entry.kind) {
    case "captures": {
      const c = entry.item;
      pills.push("Capture", `${c.pixelWidth} × ${c.pixelHeight}`, relative(new Date(c.createdAt)));
      body = <DetailImage src={`${c.url}?v=${version}`} title={captureTitle(c)} />;
      break;
    }
    case "clipboard": {
      const c = entry.item;
      const text = c.text ?? "";
      pills.push({ text: "Text", link: "Link", color: "Color", image: "Image", files: "Files" }[c.kind]);
      if (c.sourceName) pills.push(c.sourceName);
      pills.push(relative(new Date(c.createdAt)));
      if (c.kind === "image") {
        if (c.pixelWidth) pills.splice(1, 0, `${c.pixelWidth} × ${c.pixelHeight}`);
        body = <DetailImage src={cueUrl(`clip/${c.id}`)} title={c.name} />;
      } else if (c.kind === "files") {
        const files = text.split("\n").filter(Boolean);
        pills.splice(1, 0, `${files.length} ${files.length === 1 ? "file" : "files"}`);
        body = (
          <div className="detail-files">
            {files.map((f) => (
              <button key={f} className="detail-file" onClick={() => onRevealPath?.(f)} title="Show in Explorer">
                <Icon name="doc" size={13} /> <span className="file-path">{f}</span>
              </button>
            ))}
          </div>
        );
      } else if (c.kind === "color") {
        const parsed = /^#([0-9A-F]{6})$/i.exec(text);
        const value = parsed ? { red: parseInt(text.slice(1, 3), 16) / 255, green: parseInt(text.slice(3, 5), 16) / 255, blue: parseInt(text.slice(5, 7), 16) / 255 } : null;
        body = value ? <ColorFormats color={value} current={colorFormat} onCopy={onCopyText} /> : <DetailText text={text} />;
      } else {
        const language = c.kind === "text" ? detectCode(text) : null;
        pills.splice(1, 0, `${[...text].length.toLocaleString()} characters`);
        if (language) pills.splice(1, 0, language);
        body = <DetailText text={text} code={!!language} />;
      }
      break;
    }
    case "assets": {
      const a = entry.item;
      pills.push(a.kind === "image" ? "Image" : "File", a.kind === "image" && a.pixelWidth ? `${a.pixelWidth} × ${a.pixelHeight}` : byteSize(a.byteSize));
      body =
        a.kind === "image" ? (
          <DetailImage src={cueUrl(`asset/${a.id}`)} title={a.fileName} />
        ) : (
          <div className="detail-filecard">
            <Icon name="doc" size={56} weight={1.1} />
            <div className="detail-title">{a.fileName}</div>
            <div className="detail-sub">{byteSize(a.byteSize)}</div>
          </div>
        );
      break;
    }
    case "colors": {
      const c = entry.item;
      pills.push("Color", format(c.color, "hex"));
      if (c.name) pills.push(c.name);
      body = <ColorFormats color={c.color} current={colorFormat} onCopy={onCopyText} />;
      break;
    }
    case "snippets": {
      const s = entry.item;
      pills.push("Snippet", s.keyword);
      body = <DetailText text={s.text} />;
      break;
    }
    case "notes": {
      const n = entry.item;
      pills.push("Note", relative(new Date(n.updatedAt)));
      body = <Markdown text={n.text} />;
      break;
    }
  }

  return (
    <div className="detail">
      <div className="detail-header">
        <button className="back-pill" onClick={onBack}>
          <Icon name="chevron.left" size={10} weight={STROKE.bold} /> Back
        </button>
        {pills.map((p, i) => (
          <span key={i} className="info-pill">{p}</span>
        ))}
        <span className="row-spacer" />
        {buttons.map((b) => (
          <button key={b.title} className="detail-button" title={b.title} style={b.tint ? { color: b.tint } : undefined} onClick={b.onClick}>
            <Icon name={b.symbol} size={13} weight={STROKE.semibold} />
            <span>{b.title}</span>
          </button>
        ))}
      </div>
      <div className="detail-body">{body}</div>
    </div>
  );
}

function DetailImage({ src, title }: { src: string; title?: string }) {
  return (
    <div className="detail-image">
      <img src={src} alt={title ?? ""} draggable={false} />
    </div>
  );
}

function DetailText({ text, code }: { text: string; code?: boolean }) {
  return <pre className={`detail-text ${code ? "code" : ""}`}>{text}</pre>;
}

function ColorFormats({ color, current, onCopy }: { color: ColorItem["color"]; current: ColorFormat; onCopy: (text: string, format?: ColorFormat) => void }) {
  return (
    <div className="detail-color">
      <div className="detail-swatch" style={{ background: cssColor(color) }} />
      <div className="format-list">
        {FORMATS.map((f) => (
          <button key={f} className="format-row" onClick={() => onCopy(format(color, f), f)} title="Copy">
            <span className="format-name">
              {f === current && <span className="dot" />}
              {FORMAT_TITLES[f]}
            </span>
            <span className="format-value">{format(color, f)}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

/** Enough Markdown for a note: headings, lists, quotes, bold, italic and code. */
export function Markdown({ text }: { text: string }) {
  const inline = (line: string) =>
    line
      .split(/(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)/g)
      .map((part, i) =>
        part.startsWith("**") ? <strong key={i}>{part.slice(2, -2)}</strong> : part.startsWith("`") ? <code key={i}>{part.slice(1, -1)}</code> : part.startsWith("*") && part.length > 2 ? <em key={i}>{part.slice(1, -1)}</em> : part,
      );
  return (
    <div className="markdown">
      {text.split("\n").map((line, i) => {
        const heading = /^(#{1,3})\s+(.*)$/.exec(line);
        if (heading) return <div key={i} className={`md-h${heading[1].length}`}>{inline(heading[2])}</div>;
        const task = /^\s*[-*]\s+\[([ xX])\]\s+(.*)$/.exec(line);
        if (task) return <div key={i} className="md-li"><Icon name={task[1] === " " ? "circle" : "checkmark.circle.fill"} size={11} /> {inline(task[2])}</div>;
        const item = /^\s*([-*]|\d+[.)])\s+(.*)$/.exec(line);
        if (item) return <div key={i} className="md-li">• {inline(item[2])}</div>;
        if (line.startsWith(">")) return <div key={i} className="md-quote">{inline(line.replace(/^>\s?/, ""))}</div>;
        if (!line.trim()) return <div key={i} className="md-gap" />;
        return <div key={i}>{inline(line)}</div>;
      })}
    </div>
  );
}

export const detailTitle = (entry: DetailItem) => (entry.kind === "notes" ? firstLine(entry.item.text) : "");
