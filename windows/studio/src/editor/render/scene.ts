// One frame of the edit, drawn on a 2D canvas — the Mac's `SceneBuilder` + `SceneRenderer`
// for what this port supports: background, the framed picture (padding, corners, shadow,
// border, crop, aspect), the camera, the pointer and its clicks. The preview and the
// export both draw with this, so what you see is what you get.

import { CameraRig, type Picture } from "../model/camera";
import { sourceTime } from "../model/clips";
import type { CursorTrack } from "../model/cursor";
import { ASPECT_RATIOS, type FrameStyle, type Timeline } from "../model/timeline";
import { css, paintBackground } from "./backgrounds";

export type Artwork = { image: HTMLImageElement; aspect: number; hotspotX: number; hotspotY: number };

export type Ctx = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

export type Rect = { x: number; y: number; width: number; height: number };

export class Scene {
  private rig: CameraRig;
  private smoothedFor = -1;
  private smoothed: CursorTrack | null = null;
  private cropKey = "";

  constructor(
    /** Video pixels. */
    readonly videoWidth: number,
    readonly videoHeight: number,
    readonly displayScale: number,
    private readonly track: CursorTrack | null,
    private readonly artwork: Record<string, Artwork>,
    private readonly backgroundImage: () => CanvasImageSource | null,
  ) {
    this.rig = new CameraRig(null, this.picture(null));
  }

  picture(style: FrameStyle | null): Picture {
    return { width: this.videoWidth, height: this.videoHeight, displayScale: this.displayScale, crop: style?.crop ?? { x: 0, y: 0, width: 1, height: 1 } };
  }

  /** The pointer track at the edit's smoothing; rebuilt only when that changes. */
  private trackFor(t: Timeline): CursorTrack | null {
    if (!this.track) return null;
    if (this.smoothedFor !== t.cursor.smoothing) {
      this.smoothedFor = t.cursor.smoothing;
      this.smoothed = this.track.smoothed(t.cursor.smoothing);
      this.cropKey = "";
    }
    return this.smoothed;
  }

  private rigFor(t: Timeline): CameraRig {
    const track = this.trackFor(t);
    const key = JSON.stringify(t.style.crop);
    if (key !== this.cropKey) {
      this.cropKey = key;
      this.rig = new CameraRig(track, this.picture(t.style));
    }
    return this.rig;
  }

  croppedSize(style: FrameStyle) {
    const c = style.crop;
    return c ? { width: Math.max(2, c.width * this.videoWidth), height: Math.max(2, c.height * this.videoHeight) } : { width: this.videoWidth, height: this.videoHeight };
  }

  /** The output's size: the picture's area at the chosen shape, in even pixels. */
  outputSize(style: FrameStyle) {
    const source = this.croppedSize(style);
    const ratio = style.aspect === "source" ? null : style.aspect === "custom" ? style.customAspect.width / style.customAspect.height : ASPECT_RATIOS[style.aspect];
    if (!ratio) return { width: Math.round(source.width / 2) * 2, height: Math.round(source.height / 2) * 2 };
    const width = Math.sqrt(source.width * source.height * ratio);
    return { width: Math.max(2, Math.round(width / 2) * 2), height: Math.max(2, Math.round(width / ratio / 2) * 2) };
  }

  /** Where the picture sits in the output when the camera is at rest. */
  videoFrame(style: FrameStyle, output: { width: number; height: number }): Rect {
    const shorter = Math.min(output.width, output.height);
    const inset = shorter * style.padding;
    const aw = Math.max(1, output.width - inset * 2);
    const ah = Math.max(1, output.height - inset * 2);
    const source = this.croppedSize(style);
    const fit = Math.min(aw / source.width, ah / source.height);
    const w = source.width * fit;
    const h = source.height * fit;
    return { x: (output.width - w) / 2, y: (output.height - h) / 2, width: w, height: h };
  }

  camera(t: Timeline, time: number) {
    return this.rigFor(t).camera(t, time);
  }

  /**
   * Draws the frame at timeline `time` on `ctx`, whose canvas is `scale` × the output
   * size. `frame` is the recording's picture at that moment.
   */
  draw(ctx: Ctx, t: Timeline, time: number, frame: CanvasImageSource | null, scale = 1) {
    const style = t.style;
    const output = this.outputSize(style);
    const W = output.width;
    const H = output.height;
    const shorter = Math.min(W, H);
    ctx.save();
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    ctx.imageSmoothingQuality = "high";

    paintBackground(ctx, style.background, W, H, style.background.kind === "image" ? this.backgroundImage() : null, shorter * style.backgroundBlur);

    const rest = this.videoFrame(style, output);
    const camera = this.camera(t, time);
    const zoom = camera.zoom;
    const [cx, cy] = camera.center;
    // The camera brings the framed point to the middle of the hole.
    const moved: Rect = {
      x: rest.x + rest.width / 2 - cx * rest.width * zoom,
      y: rest.y + rest.height / 2 - cy * rest.height * zoom,
      width: rest.width * zoom,
      height: rest.height * zoom,
    };
    const followsCamera = t.camera.zoomsWholeFrame || zoom < 1;
    // The frame (corners, shadow, border) is the hole, or the hole moved with the camera.
    const shell = followsCamera ? moved : rest;
    const radius = Math.min(shell.width, shell.height) * style.cornerRadius;
    const sigma = shorter * style.shadowRadius * (followsCamera ? Math.max(1, zoom) : 1);

    if (style.shadowOpacity > 0 && sigma > 0 && style.background.kind !== "transparent") {
      ctx.save();
      ctx.shadowColor = `rgba(0, 0, 0, ${style.shadowOpacity})`;
      ctx.shadowBlur = sigma * 2 * scale; // shadows ignore the transform
      ctx.shadowOffsetY = sigma * 0.6 * scale;
      ctx.shadowOffsetX = 0;
      ctx.fillStyle = "#000";
      roundRect(ctx, shell, radius);
      ctx.fill();
      ctx.restore();
    }

    ctx.save();
    roundRect(ctx, shell, radius);
    ctx.clip();
    ctx.fillStyle = "#000";
    ctx.fillRect(shell.x, shell.y, shell.width, shell.height);
    if (frame) {
      const c = style.crop ?? { x: 0, y: 0, width: 1, height: 1 };
      ctx.drawImage(frame, c.x * this.videoWidth, c.y * this.videoHeight, c.width * this.videoWidth, c.height * this.videoHeight, moved.x, moved.y, moved.width, moved.height);
    }

    // The pointer and its clicks, clipped to the picture like the Mac's.
    const track = this.trackFor(t);
    if (track && !track.isEmpty && t.cursor.isVisible) {
      const source = sourceTime(t, time);
      this.drawClicks(ctx, t, source, moved, shorter, track);
      this.drawCursor(ctx, t, source, moved, shorter, zoom, track);
    }
    ctx.restore();

    if (style.borderWidth > 0) {
      const width = shorter * style.borderWidth * (followsCamera ? Math.max(1, zoom) : 1);
      ctx.save();
      ctx.strokeStyle = css(style.borderColor);
      ctx.lineWidth = width;
      roundRect(ctx, { x: shell.x + width / 2, y: shell.y + width / 2, width: shell.width - width, height: shell.height - width }, Math.max(0, radius - width / 2));
      ctx.stroke();
      ctx.restore();
    }
    ctx.restore();
  }

  private point(p: [number, number], t: Timeline, video: Rect): [number, number] | null {
    const c = t.style.crop ?? { x: 0, y: 0, width: 1, height: 1 };
    const u = ((p[0] * this.displayScale) / this.videoWidth - c.x) / c.width;
    const v = ((p[1] * this.displayScale) / this.videoHeight - c.y) / c.height;
    if (u < 0 || u > 1 || v < 0 || v > 1) return null;
    return [video.x + u * video.width, video.y + v * video.height];
  }

  private drawCursor(ctx: Ctx, t: Timeline, source: number, video: Rect, shorter: number, zoom: number, track: CursorTrack) {
    const style = t.cursor;
    let opacity = 1;
    if (style.hidesWhenIdle) opacity *= track.idleOpacity(source, style.idleDelay);
    if (opacity <= 0.001) return;
    const p = track.position(source);
    const at = p && this.point(p, t, video);
    if (!at) return;
    let scale = style.scale;
    if (style.clickEffect) scale *= track.clickScale(source);
    const size = shorter * 0.035 * scale * (style.sizeIsIndependentOfZoom ? 1 : zoom);
    if (size <= 1) return;
    const shape = style.alwaysArrow ? "arrow" : style.steadiesShape ? track.steadyShape(source) : track.shape(source);
    ctx.save();
    ctx.globalAlpha = opacity;
    const art = style.usesRecordedArtwork ? (this.artwork[shape] ?? this.artwork.arrow) : undefined;
    if (art && art.image.complete && art.image.naturalWidth > 0) {
      const w = size;
      const h = size * art.aspect;
      ctx.drawImage(art.image, at[0] - art.hotspotX * w, at[1] - art.hotspotY * h, w, h);
    } else {
      drawArrow(ctx, at[0], at[1], size, shape);
    }
    ctx.restore();
  }

  private drawClicks(ctx: Ctx, t: Timeline, source: number, video: Rect, shorter: number, track: CursorTrack) {
    const style = t.cursor;
    if (!style.clickHighlight) return;
    for (const { click, progress } of track.marks(source)) {
      const at = this.point([click.x, click.y], t, video);
      if (!at) continue;
      const p = Math.min(1, Math.max(0, progress));
      const color = style.clickColor;
      const luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
      const edge = luminance > 0.5 ? "rgba(0,0,0,0.35)" : "rgba(255,255,255,0.35)";
      ctx.save();
      if (style.clickStyle === "glow") {
        const r = (shorter * style.clickSize * (0.4 + 0.6 * (1 - Math.pow(1 - p, 2)))) / 2;
        const g = ctx.createRadialGradient(at[0], at[1], 0, at[0], at[1], r);
        g.addColorStop(0, css(color, 0.55 * (1 - p)));
        g.addColorStop(1, css(color, 0));
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(at[0], at[1], r, 0, Math.PI * 2);
        ctx.fill();
      } else {
        const rings = style.clickStyle === "ripple" ? [0, 0.18] : [0];
        for (const delay of rings) {
          const q = Math.min(1, Math.max(0, (p - delay) / (1 - delay)));
          if (q <= 0) continue;
          const eased = 1 - Math.pow(1 - q, 3);
          const radius = (shorter * style.clickSize * (0.28 + 0.72 * eased)) / 2;
          const thickness = Math.max(1.5, shorter * style.clickSize * 0.07);
          if (radius <= thickness) continue;
          const fade = Math.pow(1 - q, 1.6);
          if (delay === 0 && q < 0.5) {
            ctx.fillStyle = css(color, 0.18 * (1 - 2 * q));
            ctx.beginPath();
            ctx.arc(at[0], at[1], radius, 0, Math.PI * 2);
            ctx.fill();
          }
          ctx.lineWidth = thickness + Math.max(1.5, shorter * style.clickSize * 0.03);
          ctx.strokeStyle = edge.replace("0.35", String(0.35 * fade));
          ctx.beginPath();
          ctx.arc(at[0], at[1], radius, 0, Math.PI * 2);
          ctx.stroke();
          ctx.lineWidth = thickness;
          ctx.strokeStyle = css(color, fade);
          ctx.stroke();
        }
      }
      ctx.restore();
    }
  }
}

function roundRect(ctx: Ctx, r: Rect, radius: number) {
  ctx.beginPath();
  ctx.roundRect(r.x, r.y, r.width, r.height, Math.max(0, Math.min(radius, r.width / 2, r.height / 2)));
}

/** A drawn pointer for when the recorded artwork is missing: an arrow, or a hand's dot. */
function drawArrow(ctx: Ctx, x: number, y: number, size: number, shape: string) {
  ctx.save();
  ctx.lineJoin = "round";
  if (shape === "iBeam") {
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = size * 0.14;
    ctx.beginPath();
    ctx.moveTo(x, y - size * 0.45);
    ctx.lineTo(x, y + size * 0.45);
    ctx.stroke();
    ctx.strokeStyle = "#000";
    ctx.lineWidth = size * 0.06;
    ctx.stroke();
    ctx.restore();
    return;
  }
  // The arrow, its tip at the hotspot (0.06, 0.04 of its box).
  const s = size;
  const ox = x - 0.06 * s;
  const oy = y - 0.04 * s;
  const pts: [number, number][] = [
    [0.06, 0.04], [0.06, 0.8], [0.25, 0.63], [0.37, 0.92], [0.48, 0.87], [0.36, 0.59], [0.6, 0.59],
  ];
  ctx.beginPath();
  pts.forEach(([px, py], i) => (i ? ctx.lineTo(ox + px * s, oy + py * s) : ctx.moveTo(ox + px * s, oy + py * s)));
  ctx.closePath();
  ctx.shadowColor = "rgba(0,0,0,0.35)";
  ctx.shadowBlur = s * 0.08;
  ctx.shadowOffsetY = s * 0.03;
  ctx.fillStyle = "#000";
  ctx.fill();
  ctx.shadowColor = "transparent";
  ctx.strokeStyle = "#fff";
  ctx.lineWidth = s * 0.06;
  ctx.stroke();
  ctx.restore();
}
