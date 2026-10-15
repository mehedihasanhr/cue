// The pointer as recorded — the Mac's `CursorTrack` (TimelineKit). Positions are in points
// from the recorded area's top left; times are seconds of the recording.

export type Sample = { t: number; x: number; y: number; shape: string };
export type Click = { t: number; x: number; y: number; isSecondary: boolean };
export type InputEvent =
  | { mouseDown: { button: number; t: number; x: number; y: number } }
  | { mouseUp: { button: number; t: number; x: number; y: number } }
  | { scroll: { dx: number; dy: number; t: number } }
  | { key: { modifiers: number; t: number } }
  | { shortcut: { key: string; modifiers: string[]; t: number } };

const CLICK_ANCHOR = 0.14;
const ACTIVITY_GAP = 0.3;
const STILLNESS = 0.5;
const BRIEFEST_SHAPE = 0.15;

function parseLines<T>(text: string): T[] {
  const out: T[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      // A take cut short can end on half a line.
    }
  }
  return out;
}

export class CursorTrack {
  readonly samples: Sample[];
  readonly clicks: Click[];
  readonly activity: [number, number][];
  private readonly raw: Sample[];
  private readonly steadyShapes: { t: number; shape: string }[];

  static parse(cursorText: string, inputText: string): CursorTrack {
    const samples = parseLines<Sample>(cursorText).filter((s) => typeof s.t === "number");
    const input = parseLines<InputEvent>(inputText);
    return new CursorTrack(samples, input);
  }

  constructor(samples: Sample[], input: InputEvent[], smoothed?: { samples: Sample[]; from: CursorTrack }) {
    if (smoothed) {
      this.samples = smoothed.samples;
      this.raw = smoothed.from.samples;
      this.clicks = smoothed.from.clicks;
      this.activity = smoothed.from.activity;
      this.steadyShapes = smoothed.from.steadyShapes;
      return;
    }
    const sorted = [...samples].sort((a, b) => a.t - b.t);
    this.samples = pinned(sorted, input);
    this.raw = this.samples;
    this.clicks = input
      .flatMap((e) => ("mouseDown" in e ? [{ t: e.mouseDown.t, x: e.mouseDown.x, y: e.mouseDown.y, isSecondary: e.mouseDown.button === 1 }] : []))
      .sort((a, b) => a.t - b.t);
    this.activity = activityIn(this.samples, input);
    this.steadyShapes = steadyShapesIn(sorted);
  }

  get isEmpty() {
    return this.samples.length === 0;
  }

  private indexBefore(time: number): number {
    const s = this.samples;
    let low = 0;
    let high = s.length - 1;
    while (high - low > 1) {
      const middle = (low + high) >> 1;
      if (s[middle].t <= time) low = middle;
      else high = middle;
    }
    return low;
  }

  position(time: number): [number, number] | null {
    const s = this.samples;
    if (!s.length) return null;
    if (time <= s[0].t) return [s[0].x, s[0].y];
    const last = s[s.length - 1];
    if (time >= last.t) return [last.x, last.y];
    const low = this.indexBefore(time);
    const a = s[low];
    const b = s[low + 1];
    const span = b.t - a.t;
    if (span <= 0) return [a.x, a.y];
    const p = (time - a.t) / span;
    return [a.x + (b.x - a.x) * p, a.y + (b.y - a.y) * p];
  }

  shape(time: number): string {
    if (!this.samples.length) return "arrow";
    return this.samples[this.indexBefore(time)].shape;
  }

  /** The shape, with flickers shorter than 0.15 s left out. */
  steadyShape(time: number): string {
    const runs = this.steadyShapes;
    if (!runs.length) return this.shape(time);
    let low = 0;
    let high = runs.length - 1;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (runs[middle].t <= time) low = middle;
      else high = middle - 1;
    }
    return runs[low].shape;
  }

  /** Smoothed both ways, then pulled back onto the recorded path round each click. */
  smoothed(amount: number): CursorTrack {
    amount = Math.min(1, Math.max(0, amount));
    if (amount <= 0 || this.samples.length <= 2) return this;
    const alpha = 1 - Math.pow(amount, 0.35) * 0.92;
    const out = this.samples.map((s) => ({ ...s }));
    for (let i = 1; i < out.length; i++) {
      out[i].x = out[i].x * alpha + out[i - 1].x * (1 - alpha);
      out[i].y = out[i].y * alpha + out[i - 1].y * (1 - alpha);
    }
    for (let i = out.length - 2; i >= 0; i--) {
      out[i].x = out[i].x * alpha + out[i + 1].x * (1 - alpha);
      out[i].y = out[i].y * alpha + out[i + 1].y * (1 - alpha);
    }
    if (this.clicks.length) {
      let c = 0;
      for (let i = 0; i < out.length; i++) {
        const t = out[i].t;
        while (c + 1 < this.clicks.length && Math.abs(this.clicks[c + 1].t - t) <= Math.abs(this.clicks[c].t - t)) c++;
        const d = Math.abs(t - this.clicks[c].t);
        if (d >= CLICK_ANCHOR) continue;
        const w = (Math.cos((Math.PI * d) / CLICK_ANCHOR) + 1) / 2;
        out[i].x += (this.raw[i].x - out[i].x) * w;
        out[i].y += (this.raw[i].y - out[i].y) * w;
      }
    }
    return new CursorTrack([], [], { samples: out, from: this });
  }

  /** Clicks still showing their mark at `time`, with how far through it they are. */
  marks(time: number, length = 0.45): { click: Click; progress: number }[] {
    const out: { click: Click; progress: number }[] = [];
    for (const click of this.clicks) {
      const elapsed = time - click.t;
      if (elapsed >= 0 && elapsed < length) out.push({ click, progress: elapsed / length });
    }
    return out;
  }

  /** The pointer's little press: a dip and back over 0.28 s. */
  clickScale(time: number, length = 0.28, depth = 0.25): number {
    let click: Click | undefined;
    for (const c of this.clicks) if (c.t <= time && time - c.t < length) click = c;
    if (!click) return 1;
    const p = (time - click.t) / length;
    return 1 - depth * Math.sin(p * Math.PI * 2) * (1 - p);
  }

  /** Where the pointer has been over the last `window` seconds, the recent weighted more. */
  averagePosition(time: number, window: number): [number, number] | null {
    const s = this.samples;
    if (window <= 0 || !s.length) return this.position(time);
    const from = time - window;
    let low = 0;
    let high = s.length - 1;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (s[middle].t < from) low = middle + 1;
      else high = middle;
    }
    let x = 0;
    let y = 0;
    let total = 0;
    let index = low;
    while (index < s.length && s[index].t <= time) {
      const w = Math.max(0.05, 1 - (time - s[index].t) / (window * 1.6));
      x += s[index].x * w;
      y += s[index].y * w;
      total += w;
      index++;
    }
    if (total <= 0 || index - low <= 1) return this.position(time);
    return [x / total, y / total];
  }

  /** 1 while the pointer is in use, fading to 0 once it has rested for `delay`. */
  idleOpacity(time: number, delay: number, fadeOut = 0.35, fadeIn = 0.2): number {
    const faded = (rest: number) => (rest <= delay ? 1 : fadeOut <= 0 ? 0 : Math.max(0, 1 - (rest - delay) / fadeOut));
    const a = this.activity;
    if (!a.length) return faded(time);
    let low = 0;
    let high = a.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (a[middle][0] <= time) low = middle + 1;
      else high = middle;
    }
    const previous = low > 0 ? a[low - 1] : null;
    const next = low < a.length ? a[low] : null;
    if (previous && time <= previous[1]) return 1;
    const leaving = faded(time - (previous?.[1] ?? 0));
    if (!next || fadeIn <= 0) return leaving;
    return Math.max(leaving, 1 - Math.min(1, Math.max(0, (next[0] - time) / fadeIn)));
  }
}

/** Every press and release becomes a sample, so a click lands exactly where it was made. */
function pinned(samples: Sample[], input: InputEvent[]): Sample[] {
  if (!samples.length) return samples;
  const pins: { t: number; x: number; y: number }[] = [];
  for (const e of input) {
    if ("mouseDown" in e) pins.push(e.mouseDown);
    else if ("mouseUp" in e) pins.push(e.mouseUp);
  }
  if (!pins.length) return samples;
  const merged = [...samples];
  for (const pin of pins.sort((a, b) => a.t - b.t)) {
    let low = 0;
    let high = merged.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (merged[middle].t <= pin.t) low = middle + 1;
      else high = middle;
    }
    const shape = merged[Math.max(0, low - 1)].shape;
    if (low > 0 && merged[low - 1].t === pin.t) merged[low - 1] = { ...merged[low - 1], x: pin.x, y: pin.y };
    else merged.splice(low, 0, { t: pin.t, x: pin.x, y: pin.y, shape });
  }
  return merged;
}

function activityIn(samples: Sample[], input: InputEvent[]): [number, number][] {
  const moments: number[] = [];
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1];
    const b = samples[i];
    if (Math.hypot(b.x - a.x, b.y - a.y) > STILLNESS) moments.push(a.t, b.t);
  }
  for (const e of input) {
    if ("mouseDown" in e) moments.push(e.mouseDown.t);
    else if ("mouseUp" in e) moments.push(e.mouseUp.t);
    else if ("scroll" in e) moments.push(e.scroll.t);
  }
  moments.sort((a, b) => a - b);
  const ranges: [number, number][] = [];
  for (const m of moments) {
    const last = ranges[ranges.length - 1];
    if (last && m - last[1] <= ACTIVITY_GAP) last[1] = Math.max(last[1], m);
    else ranges.push([m, m]);
  }
  return ranges;
}

function steadyShapesIn(samples: Sample[]): { t: number; shape: string }[] {
  if (!samples.length) return [];
  const runs = [{ t: samples[0].t, shape: samples[0].shape }];
  for (const s of samples) if (s.shape !== runs[runs.length - 1].shape) runs.push({ t: s.t, shape: s.shape });
  const end = samples[samples.length - 1].t;
  const steady: { t: number; shape: string }[] = [];
  runs.forEach((run, i) => {
    const length = (i + 1 < runs.length ? runs[i + 1].t : end) - run.t;
    if (length < BRIEFEST_SHAPE && i > 0 && i + 1 < runs.length) return;
    if (steady[steady.length - 1]?.shape !== run.shape) steady.push(run);
  });
  return steady;
}
