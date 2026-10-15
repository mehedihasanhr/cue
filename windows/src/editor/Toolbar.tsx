// The editor's chrome, after the Mac's `Editor/EditorView.swift`: the toolbar (tools in
// pills by what they are for, the actions at the right), the options bar for the tool in
// hand, the status bar, and the background panel.

import { useState } from "react";
import { BACKGROUND_COLORS, GRADIENTS, RATIOS, type Background, type GradientName, type Ratio } from "./model/document";
import { css, PALETTE, sameColor, type Annotation, type RGBA } from "./model/types";
import { RANGES, type Prefs, type ShapeKind, type Tool } from "./prefs";
import { Icon, type IconName } from "../ui/icon";

const TOOL_INFO: Record<Tool, { title: string; key: string; symbol: IconName }> = {
  select: { title: "Select", key: "V", symbol: "cursorarrow" },
  crop: { title: "Crop", key: "C", symbol: "crop" },
  pencil: { title: "Pencil", key: "P", symbol: "pencil" },
  highlighter: { title: "Highlighter", key: "H", symbol: "paintbrush.pointed" },
  highlight: { title: "Highlight box", key: "M", symbol: "highlighter" },
  shape: { title: "Shape", key: "S", symbol: "square" },
  arrow: { title: "Arrow", key: "A", symbol: "arrow.down.left" },
  text: { title: "Text", key: "T", symbol: "character" },
  counter: { title: "Counter", key: "N", symbol: "number" },
  blur: { title: "Blur", key: "B", symbol: "drop.fill" },
};

const SHAPES: { kind: ShapeKind; title: string; symbol: IconName }[] = [
  { kind: "rectangle", title: "Rectangle", symbol: "square" },
  { kind: "ellipse", title: "Ellipse", symbol: "circle" },
  { kind: "line", title: "Line", symbol: "line.diagonal" },
];

/** What an annotation is called in the options bar when it is selected. */
const KIND_TITLE: Record<Annotation["type"], string> = {
  rectangle: "Rectangle",
  ellipse: "Ellipse",
  line: "Line",
  arrow: "Arrow",
  pencil: "Pencil",
  highlighter: "Highlighter",
  highlight: "Highlight box",
  text: "Text",
  counter: "Counter",
  blur: "Blur",
};

type ToolbarProps = {
  tool: Tool;
  onTool: (tool: Tool) => void;
  prefs: Prefs;
  onStyle: (patch: Partial<Prefs>) => void;
  backgroundOpen: boolean;
  onBackground: () => void;
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
  busy: boolean;
  onCopy: () => void;
  onExport: () => void;
  onDelete: () => void;
  onDone: () => void;
};

// MARK: - Toolbar

export function Toolbar(props: ToolbarProps) {
  const [copied, setCopied] = useState(false);
  const toolButton = (tool: Tool, shape?: (typeof SHAPES)[number]) => {
    const info = TOOL_INFO[tool];
    const active = props.tool === tool && (!shape || props.prefs.shapeKind === shape.kind);
    const symbol = shape?.symbol ?? (tool === "blur" && props.prefs.blurKind === "pixelate" ? "checkerboard.rectangle" : info.symbol);
    return (
      <button
        key={shape?.kind ?? tool}
        className={`tool-button ${active ? "active" : ""}`}
        title={`${shape?.title ?? info.title} (${info.key})`}
        aria-label={shape?.title ?? info.title}
        aria-pressed={active}
        onClick={() => {
          if (shape) props.onStyle({ shapeKind: shape.kind });
          props.onTool(tool);
        }}
      >
        {tool === "counter" ? <CounterGlyph /> : <Icon name={symbol} size={15} weight={1.9} />}
      </button>
    );
  };

  return (
    <header className="editor-toolbar">
      <div className="toolbar-tools" role="toolbar" aria-label="Tools">
        <ToolGroup>{toolButton("select")}</ToolGroup>
        <ToolGroup>
          <button
            className={`tool-button ${props.backgroundOpen ? "active" : ""}`}
            title="Background (G)"
            aria-label="Background"
            aria-pressed={props.backgroundOpen}
            onClick={props.onBackground}
          >
            <Icon name="photo.on.rectangle.angled" size={15} weight={1.9} />
          </button>
          {toolButton("crop")}
        </ToolGroup>
        <ToolGroup>
          {toolButton("pencil")}
          {toolButton("highlighter")}
          {toolButton("highlight")}
        </ToolGroup>
        <ToolGroup>
          {SHAPES.map((shape) => toolButton("shape", shape))}
          {toolButton("arrow")}
          {toolButton("text")}
          {toolButton("counter")}
        </ToolGroup>
        <ToolGroup>{toolButton("blur")}</ToolGroup>
      </div>

      <div className="toolbar-actions">
        <ToolGroup>
          <IconButton symbol="arrow.uturn.backward" help="Undo (Ctrl+Z)" disabled={!props.canUndo} onClick={props.onUndo} />
          <IconButton symbol="arrow.uturn.forward" help="Redo (Ctrl+Y)" disabled={!props.canRedo} onClick={props.onRedo} />
        </ToolGroup>
        <ToolGroup>
          <IconButton
            symbol={copied ? "checkmark" : "doc.on.doc"}
            help="Copy to clipboard (Ctrl+C)"
            tint={copied ? "#30d158" : undefined}
            disabled={props.busy}
            onClick={() => {
              setCopied(true);
              props.onCopy();
              window.setTimeout(() => setCopied(false), 1600);
            }}
          />
          <IconButton symbol="trash" help="Delete capture" tint="rgba(255, 69, 58, 0.9)" onClick={props.onDelete} />
        </ToolGroup>
        <button className="toolbar-pill" disabled={props.busy} title="Export a copy (Ctrl+Shift+S)" onClick={props.onExport}>
          Export…
        </button>
        <button className="toolbar-pill prominent" disabled={props.busy} title="Save and close" onClick={props.onDone}>
          Done
        </button>
      </div>
    </header>
  );
}

function ToolGroup({ children }: { children: React.ReactNode }) {
  return <div className="tool-group">{children}</div>;
}

function IconButton({ symbol, help, disabled, tint, onClick }: { symbol: IconName; help: string; disabled?: boolean; tint?: string; onClick: () => void }) {
  return (
    <button className="tool-button" title={help} aria-label={help} disabled={disabled} style={tint ? { color: tint } : undefined} onClick={onClick}>
      <Icon name={symbol} size={15} weight={1.9} />
    </button>
  );
}

/** "1" in a filled circle — the counter, which no icon set draws the Mac's way. */
function CounterGlyph() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden>
      <circle cx="8" cy="8" r="7" fill="currentColor" />
      <text x="8" y="11.6" textAnchor="middle" fontSize="10" fontWeight="700" fontFamily="Segoe UI, sans-serif" fill="var(--counter-ink, #fff)">
        1
      </text>
    </svg>
  );
}

// MARK: - Options bar

type OptionsProps = {
  tool: Tool;
  prefs: Prefs;
  selected: Annotation | null;
  onStyle: (patch: Partial<Prefs>) => void;
  onDuplicate: () => void;
  onDeleteSelected: () => void;
  onApplyCrop: () => void;
  onResetCrop: () => void;
};

/** The settings of the tool in hand, or of the selected annotation. Hidden while there is nothing to set. */
export function OptionsBar({ tool, prefs, selected, onStyle, onDuplicate, onDeleteSelected, onApplyCrop, onResetCrop }: OptionsProps) {
  // The controls follow the selection when there is one, else the tool in hand.
  const subject: string = selected?.type ?? tool;
  const isShape = subject === "shape" || subject === "rectangle" || subject === "ellipse" || subject === "line";
  const usesHighlight = subject === "highlighter" || subject === "highlight";
  const color = currentColor(selected) ?? (usesHighlight ? prefs.highlightColor : prefs.color);
  const title = selected ? KIND_TITLE[selected.type] : tool === "shape" ? SHAPES.find((s) => s.kind === prefs.shapeKind)!.title : TOOL_INFO[tool].title;
  const shapeKind = selected?.type === "rectangle" || selected?.type === "ellipse" || selected?.type === "line" ? selected.type : prefs.shapeKind;

  const colors = (
    <Swatches
      value={color}
      palette={subject === "highlight" ? HIGHLIGHT_PALETTE : PALETTE}
      onChange={(c) => onStyle(usesHighlight ? { highlightColor: c } : { color: c })}
      well={subject !== "highlight"}
    />
  );

  return (
    <div className="options-bar" aria-label={`${title} options`}>
      <span className="options-title">
        {title}
        {!selected && <kbd className="keycap">{TOOL_INFO[tool].key}</kbd>}
      </span>
      <Separator />
      {tool === "crop" && !selected ? (
        <>
          <span className="options-hint">Drag the handles, then press Enter to crop</span>
          <span className="options-spacer" />
          <OptionButton title="Reset" onClick={onResetCrop} />
          <OptionButton title="Crop" symbol="crop" role="prominent" onClick={onApplyCrop} />
        </>
      ) : (
        <>
          {subject !== "blur" && colors}
          {(isShape || subject === "arrow" || subject === "pencil") && (
            <>
              <Separator />
              <Slider label="Width" value={strokeWidth(selected) ?? prefs.strokeWidth} range={RANGES.strokeWidth} width={100} onChange={(v) => onStyle({ strokeWidth: v })} />
            </>
          )}
          {isShape && shapeKind !== "line" && (
            <>
              <Separator />
              <Segmented
                value={selected && "style" in selected && "fill" in selected.style ? selected.style.fill : prefs.fill}
                options={[["none", "Outline"], ["solid", "Filled"], ["translucent", "Tinted"]]}
                onChange={(v) => onStyle({ fill: v })}
              />
            </>
          )}
          {subject === "arrow" && (
            <>
              <Separator />
              <Segmented
                value={selected?.type === "arrow" ? selected.arrowStyle : prefs.arrowStyle}
                options={[["single", <Icon key="s" name="arrow.right" size={13} weight={2} />], ["double", <Icon key="d" name="arrow.left.and.right" size={13} weight={2} />]]}
                labels={{ single: "One end", double: "Both ends" }}
                onChange={(v) => onStyle({ arrowStyle: v })}
              />
            </>
          )}
          {subject === "pencil" && (
            <>
              <Separator />
              <button
                className={`option-toggle ${prefs.smartShapes ? "on" : ""}`}
                aria-pressed={prefs.smartShapes}
                title="Turn a drawn line, circle, box or arrow into a clean one"
                onClick={() => onStyle({ smartShapes: !prefs.smartShapes })}
              >
                <Icon name="wand.and.stars" size={13} weight={1.9} />
                Smart shapes
              </button>
            </>
          )}
          {subject === "highlighter" && (
            <>
              <Separator />
              <Slider label="Width" value={selected?.type === "highlighter" ? selected.style.width : prefs.highlighterWidth} range={RANGES.highlighterWidth} width={100} onChange={(v) => onStyle({ highlighterWidth: v })} />
            </>
          )}
          {subject === "highlight" && !selected && (
            <>
              <Separator />
              <span className="options-hint">Drag a box over text to highlight it</span>
            </>
          )}
          {subject === "text" && (
            <>
              <Separator />
              <Slider label="Size" value={selected?.type === "text" ? selected.style.fontSize : prefs.fontSize} range={RANGES.fontSize} width={96} onChange={(v) => onStyle({ fontSize: v })} />
              <Slider
                label="Weight"
                value={selected?.type === "text" ? selected.style.weight : prefs.fontWeight}
                range={[300, 900]}
                step={100}
                width={80}
                caption={(w) => WEIGHT_NAMES[w] ?? String(w)}
                captionWidth={58}
                onChange={(v) => onStyle({ fontWeight: v })}
              />
              <Separator />
              <Segmented
                value={selected?.type === "text" ? selected.style.background : prefs.textBackground}
                options={[["none", "Plain"], ["solid", "Box"], ["translucent", "Dark box"]]}
                onChange={(v) => onStyle({ textBackground: v })}
              />
            </>
          )}
          {subject === "blur" && (
            <>
              <Segmented
                value={selected?.type === "blur" ? selected.kind : prefs.blurKind}
                options={[["blur", "Blur"], ["pixelate", "Pixelate"]]}
                onChange={(v) => onStyle({ blurKind: v })}
              />
              <Separator />
              <Slider label="Intensity" value={selected?.type === "blur" ? selected.intensity : prefs.blurIntensity} range={RANGES.blurIntensity} width={120} onChange={(v) => onStyle({ blurIntensity: v })} />
            </>
          )}
          {subject === "counter" && (
            <>
              <Separator />
              <Slider label="Size" value={selected?.type === "counter" ? selected.size : prefs.counterSize} range={RANGES.counterSize} width={110} onChange={(v) => onStyle({ counterSize: v })} />
              {!selected && (
                <>
                  <Separator />
                  <span className="options-hint">Click to place 1, 2, 3…</span>
                </>
              )}
            </>
          )}
          {selected && (
            <>
              <Separator />
              <OptionButton title="Duplicate" symbol="plus.square.on.square" onClick={onDuplicate} />
              <OptionButton title="Delete" symbol="trash" role="destructive" onClick={onDeleteSelected} />
            </>
          )}
        </>
      )}
    </div>
  );
}

const WEIGHT_NAMES: Record<number, string> = { 300: "Light", 400: "Regular", 500: "Medium", 600: "Semibold", 700: "Bold", 800: "Heavy", 900: "Black" };
const HIGHLIGHT_PALETTE: RGBA[] = [
  { r: 1, g: 0.84, b: 0.04 },
  { r: 0.2, g: 0.78, b: 0.35 },
  { r: 1, g: 0.58, b: 0 },
  { r: 1, g: 0.18, b: 0.33 },
  { r: 0.04, g: 0.52, b: 1 },
  { r: 0.69, g: 0.32, b: 0.87 },
];

function Separator() {
  return <span className="options-separator" />;
}

function OptionButton({ title, symbol, role = "normal", onClick }: { title: string; symbol?: IconName; role?: "normal" | "prominent" | "destructive"; onClick: () => void }) {
  return (
    <button className={`option-button ${role}`} onClick={onClick}>
      {symbol && <Icon name={symbol} size={12} weight={2} />}
      {title}
    </button>
  );
}

function currentColor(a: Annotation | null): RGBA | null {
  if (!a) return null;
  switch (a.type) {
    case "rectangle": case "ellipse": return a.style.stroke.color;
    case "line": case "arrow": case "pencil": case "highlighter": return a.style.color;
    case "text": return a.style.color;
    case "highlight": case "counter": return a.color;
    default: return null;
  }
}

function strokeWidth(a: Annotation | null): number | null {
  if (!a) return null;
  if (a.type === "rectangle" || a.type === "ellipse") return a.style.stroke.width;
  if (a.type === "line" || a.type === "arrow" || a.type === "pencil") return a.style.width;
  return null;
}

/** A row of colour dots, the chosen one ringed, and a colour well for any other. */
function Swatches({ value, palette, onChange, well }: { value: RGBA; palette: RGBA[]; onChange: (c: RGBA) => void; well: boolean }) {
  const hex = (c: RGBA) => "#" + [c.r, c.g, c.b].map((v) => Math.round(v * 255).toString(16).padStart(2, "0")).join("");
  return (
    <div className="swatches" role="radiogroup" aria-label="Colour">
      {palette.map((c, i) => (
        <button
          key={i}
          role="radio"
          aria-checked={sameColor(c, value)}
          className={`swatch ${sameColor(c, value) ? "on" : ""}`}
          onClick={() => onChange(c)}
          aria-label={`Colour ${hex(c)}`}
        >
          <span style={{ background: css(c) }} />
        </button>
      ))}
      {well && (
        <label className="color-well" title="Other colour" style={{ background: css(value) }}>
          <input
            type="color"
            value={hex(value)}
            aria-label="Other colour"
            onChange={(e) => {
              const v = e.target.value;
              onChange({ r: parseInt(v.slice(1, 3), 16) / 255, g: parseInt(v.slice(3, 5), 16) / 255, b: parseInt(v.slice(5, 7), 16) / 255 });
            }}
          />
        </label>
      )}
    </div>
  );
}

function Slider({
  label,
  value,
  range,
  onChange,
  width = 100,
  step = 1,
  caption = (v) => String(Math.round(v)),
  captionWidth = 24,
}: {
  label: string;
  value: number;
  range: readonly [number, number];
  onChange: (v: number) => void;
  width?: number;
  step?: number;
  caption?: (v: number) => string;
  captionWidth?: number;
}) {
  const fill = ((value - range[0]) / (range[1] - range[0])) * 100;
  return (
    <label className="option-slider">
      <span className="option-label">{label}</span>
      <input
        type="range"
        min={range[0]}
        max={range[1]}
        step={step}
        value={value}
        style={{ width, ["--fill" as string]: `${fill}%` }}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      <span className="option-value" style={{ width: captionWidth }}>
        {caption(value)}
      </span>
    </label>
  );
}

function Segmented<T extends string>({ value, options, onChange, labels }: { value: T; options: [T, React.ReactNode][]; onChange: (v: T) => void; labels?: Record<string, string> }) {
  return (
    <div className="option-segmented" role="radiogroup">
      {options.map(([id, title]) => (
        <button key={id} role="radio" aria-checked={value === id} aria-label={labels?.[id]} title={labels?.[id]} className={value === id ? "on" : ""} onClick={() => onChange(id)}>
          {title}
        </button>
      ))}
    </div>
  );
}

// MARK: - Status bar

export function StatusBar({ pixelWidth, pixelHeight, scale, cropped, zoom, onZoomOut, onZoomIn, onActualSize, onFit }: {
  pixelWidth: number;
  pixelHeight: number;
  scale: number;
  cropped: boolean;
  zoom: number;
  onZoomOut: () => void;
  onZoomIn: () => void;
  onActualSize: () => void;
  onFit: () => void;
}) {
  const points = (v: number) => Math.round(v / scale);
  return (
    <footer className="status-bar">
      <span className="status-size">
        {pixelWidth} × {pixelHeight} px · {points(pixelWidth)} × {points(pixelHeight)} pt · @{Number(scale.toFixed(2))}x
      </span>
      {cropped && <span className="status-quiet">· cropped</span>}
      <span className="options-spacer" />
      <span className="status-zoom">
        <button title="Zoom out (Ctrl+−)" aria-label="Zoom out" onClick={onZoomOut}>
          <Icon name="minus" size={11} weight={2.2} />
        </button>
        <button className="status-percent" title="Actual size (Ctrl+1)" onClick={onActualSize}>
          {Math.round(zoom * 100)}%
        </button>
        <button title="Zoom in (Ctrl++)" aria-label="Zoom in" onClick={onZoomIn}>
          <Icon name="plus" size={11} weight={2.2} />
        </button>
        <button title="Fit to window (Ctrl+0)" aria-label="Fit to window" onClick={onFit}>
          <Icon name="arrow.down.left.and.arrow.up.right" size={11} weight={2.2} />
        </button>
      </span>
    </footer>
  );
}

// MARK: - Background

export function BackgroundPanel({ background, onChange, onRemove, onClose }: {
  background: Background;
  onChange: (b: Background) => void;
  onRemove: () => void;
  onClose: () => void;
}) {
  const set = (patch: Partial<Background>) => onChange({ ...background, ...patch });
  return (
    <aside className="background-panel" aria-label="Background">
      <div className="panel-head">
        <h2>Background</h2>
        <button className="tool-button" title="Close" aria-label="Close" onClick={onClose}>
          <Icon name="xmark" size={14} weight={2} />
        </button>
      </div>

      <h3>Gradient</h3>
      <div className="fills">
        {(Object.keys(GRADIENTS) as GradientName[]).map((name) => (
          <button
            key={name}
            title={name[0].toUpperCase() + name.slice(1)}
            className={`fill ${background.fill.type === "gradient" && background.fill.name === name ? "on" : ""}`}
            style={{ background: `linear-gradient(135deg, ${GRADIENTS[name].map((c) => css(c)).join(", ")})` }}
            onClick={() => set({ fill: { type: "gradient", name } })}
          />
        ))}
      </div>
      <h3>Colour</h3>
      <div className="fills">
        {BACKGROUND_COLORS.map((color, i) => (
          <button
            key={i}
            className={`fill ${background.fill.type === "solid" && sameColor(background.fill.color, color) ? "on" : ""}`}
            style={{ background: css(color) }}
            onClick={() => set({ fill: { type: "solid", color } })}
            aria-label={`Colour ${i + 1}`}
          />
        ))}
      </div>

      <div className="panel-sliders">
        <label className="check">
          <input type="checkbox" checked={background.autoBalance} onChange={(e) => set({ autoBalance: e.target.checked })} />
          Balance padding automatically
        </label>
        {!background.autoBalance && <Slider label="Padding" width={120} value={background.padding} range={[0, 200]} onChange={(padding) => set({ padding })} />}
        <Slider label="Inset" width={120} value={background.inset} range={[0, 60]} onChange={(inset) => set({ inset })} />
        <Slider label="Corners" width={120} value={background.cornerRadius} range={[0, 48]} onChange={(cornerRadius) => set({ cornerRadius })} />
        <Slider label="Shadow" width={120} value={Math.round(background.shadow * 100)} range={[0, 100]} onChange={(v) => set({ shadow: v / 100 })} />
        {background.fill.type === "gradient" && (
          <Slider label="Angle" width={120} value={background.gradientAngle} range={[0, 360]} onChange={(gradientAngle) => set({ gradientAngle })} />
        )}
      </div>

      <h3>Size</h3>
      <select value={background.ratio} onChange={(e) => set({ ratio: e.target.value as Ratio })} aria-label="Aspect ratio">
        {(Object.keys(RATIOS) as Ratio[]).map((r) => (
          <option key={r} value={r}>{r === "auto" ? "Fit the image" : r === "square" ? "1:1" : r}</option>
        ))}
      </select>
      {background.ratio !== "auto" && (
        <>
          <h3>Position</h3>
          <div className="alignment" role="radiogroup" aria-label="Position">
            {[0, 0.5, 1].flatMap((y) =>
              [0, 0.5, 1].map((x) => (
                <button
                  key={`${x}-${y}`}
                  role="radio"
                  aria-checked={background.alignment.x === x && background.alignment.y === y}
                  className={background.alignment.x === x && background.alignment.y === y ? "on" : ""}
                  onClick={() => set({ alignment: { x, y } })}
                />
              )),
            )}
          </div>
        </>
      )}
      <button className="button danger remove" onClick={onRemove}>Remove background</button>
    </aside>
  );
}
