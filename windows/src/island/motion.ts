// The island's motion: the Mac's SwiftUI springs, integrated by hand so the shape can
// morph every frame. `response` and `damping` mean what they mean to SwiftUI: the
// period of the undamped spring, and the damping ratio (1 = no bounce).

export type Curve = { kind: "spring"; response: number; damping: number } | { kind: "ease"; duration: number } | { kind: "none" };

/** Settings › Island › Animation: Lively (springs), Quick (short eases), Off. */
export function curves(style: string, reduceMotion: boolean) {
  if (style === "none") return { open: { kind: "none" } as Curve, close: { kind: "none" } as Curve, content: 0 };
  if (style === "quick" || reduceMotion) {
    return { open: { kind: "ease", duration: 0.18 } as Curve, close: { kind: "ease", duration: 0.18 } as Curve, content: 0.15 };
  }
  return {
    open: { kind: "spring", response: 0.36, damping: 0.82 } as Curve,
    close: { kind: "spring", response: 0.45, damping: 1.0 } as Curve,
    content: 0.28,
  };
}

type Channel = { value: number; velocity: number; from: number; target: number; elapsed: number };

/** Animates a few numbers towards targets along one curve, calling `draw` each frame. */
export class Animator<K extends string> {
  private channels: Record<K, Channel>;
  private curve: Curve = { kind: "none" };
  private frame = 0;
  private last = 0;

  constructor(initial: Record<K, number>, private draw: (values: Record<K, number>) => void) {
    this.channels = Object.fromEntries(
      Object.entries(initial).map(([k, v]) => [k, { value: v as number, velocity: 0, from: v as number, target: v as number, elapsed: 0 }]),
    ) as Record<K, Channel>;
  }

  values(): Record<K, number> {
    return Object.fromEntries(Object.entries(this.channels).map(([k, c]) => [k, (c as Channel).value])) as Record<K, number>;
  }

  /** Retargets; a spring keeps its velocity, so an interrupted motion turns smoothly. */
  to(targets: Partial<Record<K, number>>, curve: Curve) {
    this.curve = curve;
    for (const [key, target] of Object.entries(targets) as [K, number][]) {
      const channel = this.channels[key];
      channel.from = channel.value;
      channel.target = target;
      channel.elapsed = 0;
      if (curve.kind === "none") {
        channel.value = target;
        channel.velocity = 0;
      }
    }
    if (curve.kind === "none") {
      this.draw(this.values());
      return;
    }
    if (!this.frame) {
      this.last = performance.now();
      this.frame = requestAnimationFrame(this.tick);
    }
  }

  private tick = (now: number) => {
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    let moving = false;
    for (const channel of Object.values(this.channels) as Channel[]) {
      if (this.curve.kind === "spring") {
        const stiffness = Math.pow((2 * Math.PI) / this.curve.response, 2);
        const friction = (4 * Math.PI * this.curve.damping) / this.curve.response;
        // Sub-steps keep a stiff spring stable at 60 Hz.
        for (let i = 0; i < 4; i++) {
          const h = dt / 4;
          const force = -stiffness * (channel.value - channel.target) - friction * channel.velocity;
          channel.velocity += force * h;
          channel.value += channel.velocity * h;
        }
        if (Math.abs(channel.value - channel.target) > 0.05 || Math.abs(channel.velocity) > 0.5) moving = true;
        else {
          channel.value = channel.target;
          channel.velocity = 0;
        }
      } else if (this.curve.kind === "ease") {
        channel.elapsed += dt;
        const t = Math.min(1, channel.elapsed / this.curve.duration);
        const eased = 1 - Math.pow(1 - t, 3);
        channel.value = channel.from + (channel.target - channel.from) * eased;
        if (t < 1) moving = true;
      }
    }
    this.draw(this.values());
    this.frame = moving ? requestAnimationFrame(this.tick) : 0;
  };
}

/**
 * The island silhouette — the Mac's `NotchShape`: top corners flare outward into the
 * top of the screen, bottom corners are rounded. `width` is the body; the flares lie
 * either side of it, so the path is `width + 2 × flare` wide.
 */
export function notchPath(width: number, height: number, flare: number, bottomRadius: number): string {
  const f = Math.min(flare, (width + flare * 2) / 4);
  const left = f;
  const right = f + width;
  const bottom = Math.min(bottomRadius, width / 2, height / 2);
  const total = width + f * 2;
  return [
    `M 0 0`,
    f > 0 ? `Q ${left} 0 ${left} ${f}` : `L ${left} 0`,
    `L ${left} ${height - bottom}`,
    `Q ${left} ${height} ${left + bottom} ${height}`,
    `L ${right - bottom} ${height}`,
    `Q ${right} ${height} ${right} ${height - bottom}`,
    f > 0 ? `L ${right} ${f}` : `L ${right} 0`,
    f > 0 ? `Q ${right} 0 ${total} 0` : `L ${total} 0`,
    "Z",
  ].join(" ");
}
