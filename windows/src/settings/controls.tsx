// The parts every settings page is built from, after the Mac's `SettingsRoot.swift`:
// a page of groups, a group a card of rows, a row a title (and what it does) on the
// left with its control on the right, and the controls themselves drawn the Mac's way.

import { useEffect, useRef, useState, type ReactNode } from "react";
import { Icon, type IconName } from "../ui/icon";

/** The system colours a tile is tinted with (the Mac's dark-appearance values). */
export const TINT = {
  gray: "#8e8e93",
  plum: "#bf4d80",
  indigo: "#5e5ce6",
  blue: "#0a84ff",
  pink: "#ff375f",
  green: "#30d158",
  brand: "#0e4fec",
  orange: "#ff9f0a",
  red: "#ff453a",
  purple: "#bf5af2",
  teal: "#40c8e0",
  mint: "#63e6e2",
  yellow: "#ffd60a",
  cyan: "#64d2ff",
} as const;
export type Tint = keyof typeof TINT;

/** A rounded square of colour with a white symbol: what a row or a page is about. */
export function SymbolTile({ symbol, tint, size = 28 }: { symbol: IconName; tint: Tint; size?: number }) {
  const color = TINT[tint];
  return (
    <span
      className="symbol-tile"
      style={{
        width: size,
        height: size,
        borderRadius: size / 4,
        background: `linear-gradient(to bottom, color-mix(in srgb, ${color}, white 16%), ${color})`,
      }}
    >
      <Icon name={symbol} size={size / 2 + 1} weight={size >= 48 ? 2.1 : 1.9} />
    </span>
  );
}

/** A page: groups top to bottom, under the history pill; a feature's own switch at the top right. */
export function Pane({ children, enabled }: { children: ReactNode; enabled?: { title: string; on: boolean; set: (on: boolean) => void } }) {
  return (
    <div className="pane">
      {enabled && (
        <div className="feature-switch" title={enabled.on ? `Turn ${enabled.title.toLowerCase()} off` : `Turn ${enabled.title.toLowerCase()} on`}>
          <Switch checked={enabled.on} onChange={enabled.set} label={enabled.title} small />
        </div>
      )}
      <div className="pane-body">{children}</div>
    </div>
  );
}

/** A card of rows, with a plain title above and, when something went wrong, a note below. */
export function Group({ title, footer, disabled, children }: { title?: string; footer?: string; disabled?: boolean; children: ReactNode }) {
  return (
    <section className={`group ${disabled ? "disabled" : ""}`} aria-disabled={disabled || undefined}>
      {title && <h2>{title}</h2>}
      <div className="group-card">{children}</div>
      {footer && <p className="group-footer">{footer}</p>}
    </section>
  );
}

/** One labelled row: a tile when it is about a thing, the title and subtitle, then its control. */
export function Row(props: {
  title: string;
  subtitle?: ReactNode;
  symbol?: IconName;
  tint?: Tint;
  disabled?: boolean;
  children?: ReactNode;
}) {
  return (
    <div className={`row ${props.subtitle ? "has-subtitle" : ""} ${props.disabled ? "disabled" : ""}`}>
      {props.symbol && <SymbolTile symbol={props.symbol} tint={props.tint ?? "blue"} />}
      <div className="row-text">
        <div className="row-title">{props.title}</div>
        {props.subtitle && <div className="row-subtitle">{props.subtitle}</div>}
      </div>
      {props.children !== undefined && <div className="row-control">{props.children}</div>}
    </div>
  );
}

/** Anything in a card, padded, with the hairline under it. */
export function Cell({ children, vertical = 12 }: { children: ReactNode; vertical?: number }) {
  return (
    <div className="row" style={{ paddingTop: vertical, paddingBottom: vertical }}>
      {children}
    </div>
  );
}

/** The Mac's small switch. */
export function Switch({ checked, onChange, label, small, disabled }: { checked: boolean; onChange: (on: boolean) => void; label: string; small?: boolean; disabled?: boolean }) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      className={`switch ${checked ? "on" : ""} ${small ? "small" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <span />
    </button>
  );
}

/** A segmented picker: a few choices side by side, the chosen one raised. */
export function Segmented<T extends string | number>({
  value,
  options,
  onChange,
  label,
  disabled,
}: {
  value: T;
  options: { value: T; title?: string; symbol?: IconName }[];
  onChange: (value: T) => void;
  label: string;
  disabled?: boolean;
}) {
  return (
    <div className="segmented" role="radiogroup" aria-label={label}>
      {options.map((option) => (
        <button
          key={String(option.value)}
          role="radio"
          aria-checked={option.value === value}
          aria-label={option.title}
          disabled={disabled}
          className={option.value === value ? "on" : ""}
          onClick={() => onChange(option.value)}
        >
          {option.symbol && <Icon name={option.symbol} size={13} weight={1.8} />}
          {option.title && <span>{option.title}</span>}
        </button>
      ))}
    </div>
  );
}

/** A pop-up button: the choice on a pill with the up-down chevron, the system's menu when clicked. */
export function Select<T extends string>({
  value,
  options,
  onChange,
  label,
  width,
  disabled,
}: {
  value: T;
  options: { value: T; title: string }[];
  onChange: (value: T) => void;
  label: string;
  width?: number;
  disabled?: boolean;
}) {
  return (
    <span className="select" style={width ? { width } : undefined}>
      <select value={value} aria-label={label} disabled={disabled} onChange={(e) => onChange(e.target.value as T)}>
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.title}
          </option>
        ))}
      </select>
      <Icon name="chevron.up.chevron.down" size={11} weight={2} />
    </span>
  );
}

/** A slider with its value beside it, the Mac's `SecondsSlider` and `SliderRow`. */
export function Slider({
  value,
  min,
  max,
  step,
  onChange,
  caption,
  label,
  width = 150,
  captionWidth = 52,
  disabled,
}: {
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  caption: string;
  label: string;
  width?: number;
  captionWidth?: number;
  disabled?: boolean;
}) {
  // Dragging updates the page at once and saves on release, so the file is written once.
  const [live, setLive] = useState(value);
  useEffect(() => setLive(value), [value]);
  const fraction = (live - min) / (max - min);
  return (
    <span className="slider">
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={live}
        aria-label={label}
        disabled={disabled}
        style={{ width, ["--fill" as string]: `${fraction * 100}%` }}
        onChange={(e) => setLive(Number(e.target.value))}
        onPointerUp={() => live !== value && onChange(live)}
        onKeyUp={() => live !== value && onChange(live)}
      />
      <span className="slider-caption" style={{ width: captionWidth }}>
        {caption.replace("{}", formatNumber(live))}
      </span>
    </span>
  );
}

function formatNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : String(Number(value.toPrecision(2)));
}

/** Seconds as the Mac shows them: "0.25 s", or a word for the low end. */
export function seconds(value: number, min: number, zero?: string): string {
  if (zero && value <= min) return zero;
  return `${Number(value.toPrecision(2))} s`;
}

/** A − value + stepper. */
export function Stepper({ value, min, max, onChange, label }: { value: number; min: number; max: number; onChange: (value: number) => void; label: string }) {
  return (
    <span className="stepper" aria-label={label}>
      <span className="stepper-value">{value}</span>
      <span className="stepper-buttons">
        <button aria-label={`More ${label.toLowerCase()}`} disabled={value >= max} onClick={() => onChange(value + 1)}>
          <Icon name="chevron.up" size={10} weight={2.2} />
        </button>
        <button aria-label={`Fewer ${label.toLowerCase()}`} disabled={value <= min} onClick={() => onChange(value - 1)}>
          <Icon name="chevron.down" size={10} weight={2.2} />
        </button>
      </span>
    </span>
  );
}

/** A text field that saves when it loses focus or Enter is pressed. */
export function Field({
  value,
  onCommit,
  placeholder,
  secret,
  width = 240,
  label,
}: {
  value: string;
  onCommit: (value: string) => void;
  placeholder?: string;
  secret?: boolean;
  width?: number;
  label: string;
}) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (ref.current && document.activeElement !== ref.current) ref.current.value = value;
  }, [value]);
  return (
    <input
      ref={ref}
      className="text-field"
      style={{ width }}
      defaultValue={value}
      type={secret ? "password" : "text"}
      placeholder={placeholder}
      aria-label={label}
      spellCheck={false}
      onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
      onBlur={(e) => e.target.value.trim() !== value && onCommit(e.target.value.trim())}
    />
  );
}

/** A row that chooses by picture: a tile per option, the chosen one ringed in the brand colour.
 *  With `popover`, the row shows the chosen one on a button and the tiles open under it. */
export function PreviewPicker<T extends string>({
  title,
  subtitle,
  value,
  options,
  onChange,
  preview,
  columns = 3,
  tileWidth = 104,
  popover,
  disabled,
}: {
  title: string;
  subtitle?: string;
  value: T;
  options: { value: T; title: string }[];
  onChange: (value: T) => void;
  preview: (value: T) => ReactNode;
  columns?: number;
  tileWidth?: number;
  popover?: boolean;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const anchor = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => {
      if (!anchor.current?.contains(event.target as Node)) setOpen(false);
    };
    const escape = (event: KeyboardEvent) => event.key === "Escape" && setOpen(false);
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", escape);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", escape);
    };
  }, [open]);

  const grid = (
    <div className="preview-grid" style={{ gridTemplateColumns: `repeat(${columns}, ${tileWidth}px)` }}>
      {options.map((option) => (
        <button
          key={option.value}
          className={`preview-option ${option.value === value ? "on" : ""}`}
          aria-pressed={option.value === value}
          disabled={disabled}
          onClick={() => {
            onChange(option.value);
            setOpen(false);
          }}
        >
          <span className="preview-frame" style={{ width: tileWidth, height: tileWidth / 1.5 }}>
            {preview(option.value)}
          </span>
          <span className="preview-label">{option.title}</span>
        </button>
      ))}
    </div>
  );

  if (popover) {
    const chosen = options.find((o) => o.value === value);
    return (
      <Row title={title} subtitle={subtitle} disabled={disabled}>
        <div className="preview-popover-anchor" ref={anchor}>
          <button className="preview-button" disabled={disabled} aria-expanded={open} onClick={() => setOpen(!open)}>
            <span className="preview-thumb">{preview(value)}</span>
            <span>{chosen?.title}</span>
            <Icon name="chevron.up.chevron.down" size={10} weight={2} />
          </button>
          {open && <div className="preview-popover">{grid}</div>}
        </div>
      </Row>
    );
  }
  return (
    <div className={`row preview-row ${disabled ? "disabled" : ""}`}>
      <div className="row-text" style={{ width: 170, flex: "none" }}>
        <div className="row-title">{title}</div>
        {subtitle && <div className="row-subtitle">{subtitle}</div>}
      </div>
      <div style={{ flex: 1 }} />
      {grid}
    </div>
  );
}
