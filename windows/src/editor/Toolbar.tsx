// The editor's toolbar, the style controls for the tool in hand, and the background panel.

import type { ReactNode } from "react";
import { BACKGROUND_COLORS, GRADIENTS, RATIOS, type Background, type GradientName, type Ratio } from "./model/document";
import { css, PALETTE, sameColor, type Annotation, type RGBA } from "./model/types";
import { RANGES, type Prefs, type Tool } from "./prefs";

const stroke = { fill: "none", stroke: "currentColor", strokeWidth: 1.7, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
const Icon = ({ children }: { children: ReactNode }) => (
  <svg width="18" height="18" viewBox="0 0 24 24" {...stroke} aria-hidden>{children}</svg>
);

const TOOLS: { id: Tool; title: string; key: string; icon: ReactNode }[] = [
  { id: "select", title: "Select", key: "V", icon: <Icon><path d="M5 3l14 8-6 1.5L10 19z" /></Icon> },
  { id: "crop", title: "Crop", key: "C", icon: <Icon><path d="M6 2v14a2 2 0 0 0 2 2h14M2 6h14a2 2 0 0 1 2 2v14" /></Icon> },
  { id: "arrow", title: "Arrow", key: "A", icon: <Icon><path d="M5 19 19 5M10 5h9v9" /></Icon> },
  { id: "shape", title: "Shape", key: "S", icon: <Icon><rect x="4" y="5" width="16" height="14" rx="1.5" /></Icon> },
  { id: "pencil", title: "Pencil", key: "P", icon: <Icon><path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z" /></Icon> },
  { id: "highlighter", title: "Highlighter", key: "H", icon: <Icon><path d="m9 15 7-7 3 3-7 7H9zM4 21h7" /></Icon> },
  { id: "highlight", title: "Highlight box", key: "M", icon: <Icon><rect x="3" y="7" width="18" height="10" rx="2" fill="currentColor" fillOpacity="0.25" /></Icon> },
  { id: "text", title: "Text", key: "T", icon: <Icon><path d="M5 7V5h14v2M12 5v14M9 19h6" /></Icon> },
  { id: "counter", title: "Counter", key: "N", icon: <Icon><circle cx="12" cy="12" r="8" /><path d="M11 9l2-1v8" /></Icon> },
  { id: "blur", title: "Blur", key: "B", icon: <Icon><path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z" /></Icon> },
];

type ToolbarProps = {
  tool: Tool;
  onTool: (tool: Tool) => void;
  prefs: Prefs;
  selected: Annotation | null;
  onStyle: (patch: Partial<Prefs>) => void;
  hasBackground: boolean;
  backgroundOpen: boolean;
  onBackground: () => void;
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
  onApplyCrop: () => void;
  onResetCrop: () => void;
  hasCrop: boolean;
  busy: boolean;
  onCopy: () => void;
  onSaveAs: () => void;
  onDone: () => void;
  zoom: number;
  onFit: () => void;
};

export function Toolbar(props: ToolbarProps) {
  const { tool, prefs, selected, onStyle } = props;
  // The controls follow the selection when there is one, else the tool in hand.
  const subject: string = selected?.type ?? tool;

  return (
    <header className="editor-bar">
      <div className="bar-row">
        <div className="tools" role="toolbar" aria-label="Tools">
          {TOOLS.map((t) => (
            <button
              key={t.id}
              className={`tool ${props.tool === t.id ? "active" : ""}`}
              title={`${t.title} (${t.key})`}
              aria-pressed={props.tool === t.id}
              onClick={() => props.onTool(t.id)}
            >
              {t.icon}
            </button>
          ))}
          <span className="divider" />
          <button
            className={`tool ${props.backgroundOpen ? "active" : ""}`}
            title="Background (G)"
            aria-pressed={props.backgroundOpen}
            onClick={props.onBackground}
          >
            <Icon><rect x="3" y="3" width="18" height="18" rx="3" /><rect x="7" y="7" width="10" height="10" rx="1.5" /></Icon>
          </button>
        </div>

        <div className="actions">
          <button className="zoom" title="Fit (Ctrl+0)" onClick={props.onFit}>{Math.round(props.zoom * 100)}%</button>
          <button className="tool" title="Undo (Ctrl+Z)" disabled={!props.canUndo} onClick={props.onUndo}>
            <Icon><path d="M9 14 4 9l5-5M4 9h11a5 5 0 0 1 0 10h-3" /></Icon>
          </button>
          <button className="tool" title="Redo (Ctrl+Y)" disabled={!props.canRedo} onClick={props.onRedo}>
            <Icon><path d="m15 14 5-5-5-5M20 9H9a5 5 0 0 0 0 10h3" /></Icon>
          </button>
          <button className="button" disabled={props.busy} onClick={props.onCopy} title="Copy (Ctrl+C)">Copy</button>
          <button className="button" disabled={props.busy} onClick={props.onSaveAs} title="Save a copy (Ctrl+Shift+S)">Save As…</button>
          <button className="button primary" disabled={props.busy} onClick={props.onDone} title="Save and close">Done</button>
        </div>
      </div>
      <div className="style-controls" aria-label="Style">
        {tool === "crop" && !selected ? (
          <>
            <span className="hint">Drag to crop · Enter to apply</span>
            <button className="button primary" onClick={props.onApplyCrop}>Apply</button>
            {props.hasCrop && <button className="button" onClick={props.onResetCrop}>Reset</button>}
          </>
        ) : (
          <StyleControls subject={subject} prefs={prefs} selected={selected} onStyle={onStyle} />
        )}
      </div>
    </header>
  );
}

function StyleControls({ subject, prefs, selected, onStyle }: { subject: string; prefs: Prefs; selected: Annotation | null; onStyle: (p: Partial<Prefs>) => void }) {
  const isShape = subject === "shape" || subject === "rectangle" || subject === "ellipse" || subject === "line";
  const usesHighlight = subject === "highlighter" || subject === "highlight";
  const color = currentColor(selected) ?? (usesHighlight ? prefs.highlightColor : prefs.color);

  return (
    <>
      {subject !== "blur" && subject !== "select" && (
        <Swatches value={color} onChange={(c) => onStyle(usesHighlight ? { highlightColor: c } : { color: c })} />
      )}
      {(isShape || subject === "arrow" || subject === "pencil") && (
        <Slider label="Width" value={strokeWidth(selected) ?? prefs.strokeWidth} range={RANGES.strokeWidth} onChange={(v) => onStyle({ strokeWidth: v })} />
      )}
      {subject === "shape" && (
        <Segmented
          value={prefs.shapeKind}
          options={[["rectangle", "Rectangle"], ["ellipse", "Ellipse"], ["line", "Line"]]}
          onChange={(v) => onStyle({ shapeKind: v })}
        />
      )}
      {(subject === "shape" || subject === "rectangle" || subject === "ellipse") && prefs.shapeKind !== "line" && (
        <Segmented
          value={selected && "style" in selected && "fill" in selected.style ? selected.style.fill : prefs.fill}
          options={[["none", "Outline"], ["translucent", "Tint"], ["solid", "Solid"]]}
          onChange={(v) => onStyle({ fill: v })}
        />
      )}
      {subject === "arrow" && (
        <Segmented
          value={selected?.type === "arrow" ? selected.arrowStyle : prefs.arrowStyle}
          options={[["single", "→"], ["double", "↔"]]}
          onChange={(v) => onStyle({ arrowStyle: v })}
        />
      )}
      {subject === "highlighter" && (
        <Slider label="Width" value={selected?.type === "highlighter" ? selected.style.width : prefs.highlighterWidth} range={RANGES.highlighterWidth} onChange={(v) => onStyle({ highlighterWidth: v })} />
      )}
      {subject === "text" && (
        <>
          <Slider label="Size" value={selected?.type === "text" ? selected.style.fontSize : prefs.fontSize} range={RANGES.fontSize} onChange={(v) => onStyle({ fontSize: v })} />
          <select
            value={selected?.type === "text" ? selected.style.weight : prefs.fontWeight}
            onChange={(e) => onStyle({ fontWeight: Number(e.target.value) })}
            aria-label="Weight"
          >
            {[[300, "Light"], [400, "Regular"], [500, "Medium"], [600, "Semibold"], [700, "Bold"], [900, "Black"]].map(([w, name]) => (
              <option key={w} value={w}>{name}</option>
            ))}
          </select>
          <Segmented
            value={selected?.type === "text" ? selected.style.background : prefs.textBackground}
            options={[["none", "Plain"], ["solid", "Filled"], ["translucent", "Dark"]]}
            onChange={(v) => onStyle({ textBackground: v })}
          />
        </>
      )}
      {subject === "counter" && (
        <Slider label="Size" value={selected?.type === "counter" ? selected.size : prefs.counterSize} range={RANGES.counterSize} onChange={(v) => onStyle({ counterSize: v })} />
      )}
      {subject === "blur" && (
        <>
          <Segmented
            value={selected?.type === "blur" ? selected.kind : prefs.blurKind}
            options={[["blur", "Blur"], ["pixelate", "Pixelate"]]}
            onChange={(v) => onStyle({ blurKind: v })}
          />
          <Slider label="Amount" value={selected?.type === "blur" ? selected.intensity : prefs.blurIntensity} range={RANGES.blurIntensity} onChange={(v) => onStyle({ blurIntensity: v })} />
        </>
      )}
      {subject === "pencil" && (
        <label className="check" title="Turn rough lines, boxes, circles and arrows into clean ones">
          <input type="checkbox" checked={prefs.smartShapes} onChange={(e) => onStyle({ smartShapes: e.target.checked })} />
          Smart shapes
        </label>
      )}
    </>
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

function Swatches({ value, onChange }: { value: RGBA; onChange: (c: RGBA) => void }) {
  return (
    <div className="swatches" role="radiogroup" aria-label="Colour">
      {PALETTE.map((c, i) => (
        <button
          key={i}
          role="radio"
          aria-checked={sameColor(c, value)}
          className={`swatch ${sameColor(c, value) ? "on" : ""}`}
          style={{ background: css(c) }}
          onClick={() => onChange(c)}
          aria-label={`Colour ${i + 1}`}
        />
      ))}
    </div>
  );
}

function Slider({ label, value, range, onChange }: { label: string; value: number; range: readonly [number, number]; onChange: (v: number) => void }) {
  return (
    <label className="slider">
      <span>{label}</span>
      <input type="range" min={range[0]} max={range[1]} step={1} value={value} onChange={(e) => onChange(Number(e.target.value))} />
      <span className="value">{Math.round(value)}</span>
    </label>
  );
}

function Segmented<T extends string>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map(([id, title]) => (
        <button key={id} role="radio" aria-checked={value === id} className={value === id ? "on" : ""} onClick={() => onChange(id)}>
          {title}
        </button>
      ))}
    </div>
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
        <button className="tool" title="Close" onClick={onClose}>
          <Icon><path d="M6 6l12 12M18 6 6 18" /></Icon>
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
        {!background.autoBalance && <Slider label="Padding" value={background.padding} range={[0, 200]} onChange={(padding) => set({ padding })} />}
        <Slider label="Inset" value={background.inset} range={[0, 60]} onChange={(inset) => set({ inset })} />
        <Slider label="Corners" value={background.cornerRadius} range={[0, 48]} onChange={(cornerRadius) => set({ cornerRadius })} />
        <Slider label="Shadow" value={Math.round(background.shadow * 100)} range={[0, 100]} onChange={(v) => set({ shadow: v / 100 })} />
        {background.fill.type === "gradient" && (
          <Slider label="Angle" value={background.gradientAngle} range={[0, 360]} onChange={(gradientAngle) => set({ gradientAngle })} />
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
