// Export — the Mac's `ExportModel` settings, written with WebCodecs: every frame is drawn
// by the same `Scene` as the preview, encoded to H.264, the sound mixed along the edit
// and encoded to AAC (Opus where this PC has no AAC encoder), into an MP4.

import { Muxer, StreamTarget } from "mp4-muxer";
import { fileUrl, joinPath, media } from "../../lib/ipc";
import { clipDuration, duration as editLength } from "../model/clips";
import type { Timeline } from "../model/timeline";
import type { Scene } from "../render/scene";
import { dequeued } from "./codec";
import { FrameSource } from "./frames";

export type Quality = "smaller" | "good" | "better" | "best";
export type ExportSettings = {
  /** Longest side, or null for the project's own size. */
  maxSide: number | null;
  fps: 30 | 60;
  quality: Quality;
};

/** Bits per pixel per frame — the Mac's. */
const BPP: Record<Quality, number> = { smaller: 0.022, good: 0.07, better: 0.14, best: 0.25 };
export const SEND: ExportSettings = { maxSide: 1920, fps: 60, quality: "better" };

export function exportSize(projectSize: { width: number; height: number }, maxSide: number | null) {
  const longest = Math.max(projectSize.width, projectSize.height);
  const k = maxSide && longest > maxSide ? maxSide / longest : 1;
  return { width: Math.max(2, Math.round((projectSize.width * k) / 2) * 2), height: Math.max(2, Math.round((projectSize.height * k) / 2) * 2) };
}

export const bitrate = (w: number, h: number, fps: number, q: Quality) => Math.min(200e6, Math.max(1e6, Math.round(w * h * BPP[q] * fps)));

export type Progress = { phase: "sound" | "picture" | "finishing"; fraction: number };

export async function exportVideo(job: {
  packagePath: string;
  timeline: Timeline;
  scene: Scene;
  sound: { path: string; gain: number }[];
  output: string;
  settings: ExportSettings;
  onProgress: (p: Progress) => void;
  signal: AbortSignal;
}): Promise<void> {
  const { timeline: t, scene, settings, signal } = job;
  const project = scene.outputSize(t.style);
  const { width, height } = exportSize(project, settings.maxSide);
  const fps = settings.fps;
  const length = editLength(t);
  const frames = Math.max(1, Math.round(length * fps));

  const videoConfig = await pickVideoConfig(width, height, fps, bitrate(width, height, fps, settings.quality));
  const audible = job.sound.filter((s) => s.gain > 0);
  const audioConfig = audible.length ? await pickAudioConfig() : null;

  await media.begin(job.output);
  let writes = Promise.resolve();
  let writeError: unknown = null;
  const target = new StreamTarget({
    chunked: true,
    chunkSize: 4 * 1024 * 1024,
    onData: (data, position) => {
      const copy = data.slice();
      writes = writes.then(() => media.write(job.output, position, copy)).catch((e) => {
        writeError = e;
      });
    },
  });
  const muxer = new Muxer({
    target,
    video: { codec: "avc", width, height, frameRate: fps },
    audio: audioConfig ? { codec: audioConfig.muxCodec, numberOfChannels: 2, sampleRate: 48000 } : undefined,
    fastStart: false,
    firstTimestampBehavior: "offset",
  });

  const source = new FrameSource(joinPath(job.packagePath, "media/screen.mp4"));
  let failed: unknown = null;
  try {
    // Sound first: it is quick, and the picture is what the progress is mostly about.
    if (audioConfig) {
      job.onProgress({ phase: "sound", fraction: 0 });
      const mixed = await mix(job.packagePath, t, audible, length);
      if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
      await encodeAudio(mixed, audioConfig.config, muxer);
    }

    job.onProgress({ phase: "picture", fraction: 0 });
    await source.open();
    let encodeError: unknown = null;
    const encoder = new VideoEncoder({
      output: (chunk, meta) => {
        try {
          muxer.addVideoChunk(chunk, meta);
        } catch (e) {
          encodeError = e;
        }
          },
      error: (e) => {
        encodeError = e;
      },
    });
    encoder.configure(videoConfig);

    const canvas = new OffscreenCanvas(width, height);
    const ctx = canvas.getContext("2d", { alpha: false })!;
    const scale = width / project.width;
    // Walk the edit clip by clip, so a frame's source time is exact.
    for (let i = 0; i < frames; i++) {
      if (signal.aborted) throw new DOMException("Cancelled", "AbortError");
      if (encodeError) throw encodeError;
      if (writeError) throw writeError;
      const time = i / fps;
      const frame = await source.frameAt(sourceSeconds(t, time));
      scene.draw(ctx, t, time, frame, scale);
      const out = new VideoFrame(canvas, { timestamp: Math.round((i * 1e6) / fps), duration: Math.round(1e6 / fps) });
      encoder.encode(out, { keyFrame: i % (fps * 2) === 0 });
      out.close();
      // Some encoders hold a few frames to look ahead before putting any out, so the limit
      // leaves them room.
      while (encoder.encodeQueueSize > 30 && !encodeError) await dequeued(encoder);
      if (i % 10 === 0) job.onProgress({ phase: "picture", fraction: i / frames });
    }
    job.onProgress({ phase: "finishing", fraction: 1 });
    await encoder.flush();
    encoder.close();
    if (encodeError) throw encodeError;
    muxer.finalize();
    await writes;
    if (writeError) throw writeError;
  } catch (e) {
    failed = e;
  } finally {
    source.close();
    await writes.catch(() => {});
    await media.end(job.output, failed === null);
  }
  if (failed) throw failed;
}

function sourceSeconds(t: Timeline, time: number): number {
  let elapsed = 0;
  for (const clip of t.clips) {
    const d = clipDuration(clip);
    if (time < elapsed + d || clip === t.clips[t.clips.length - 1]) {
      const offset = Math.min(Math.max(0, time - elapsed), d);
      return clip.hold !== undefined ? clip.sourceStart : clip.sourceStart + offset * clip.speed;
    }
    elapsed += d;
  }
  return 0;
}

/** H.264 High at a level the size needs, falling back to Main and Baseline. */
async function pickVideoConfig(width: number, height: number, fps: number, bits: number): Promise<VideoEncoderConfig> {
  const rate = width * height * fps;
  const level = rate <= 1920 * 1088 * 30 ? 0x28 : rate <= 1920 * 1088 * 60 ? 0x2a : rate <= 4096 * 2304 * 30 ? 0x33 : 0x34;
  const hex = level.toString(16);
  const tries: string[] = [`avc1.6400${hex}`, `avc1.4d00${hex}`, `avc1.4200${hex}`, "avc1.640034"];
  for (const codec of tries) {
    for (const hardwareAcceleration of ["prefer-hardware", "no-preference"] as const) {
      const config: VideoEncoderConfig = { codec, width, height, bitrate: bits, framerate: fps, hardwareAcceleration, latencyMode: "realtime", avc: { format: "avc" } };
      const support = await VideoEncoder.isConfigSupported(config).catch(() => null);
      if (support?.supported) return config;
    }
  }
  throw new Error(`This PC can't encode H.264 video at ${width} × ${height}.`);
}

async function pickAudioConfig(): Promise<{ config: AudioEncoderConfig; muxCodec: "aac" | "opus" } | null> {
  const aac: AudioEncoderConfig = { codec: "mp4a.40.2", sampleRate: 48000, numberOfChannels: 2, bitrate: 192000 };
  if ((await AudioEncoder.isConfigSupported(aac).catch(() => null))?.supported) return { config: aac, muxCodec: "aac" };
  const opus: AudioEncoderConfig = { codec: "opus", sampleRate: 48000, numberOfChannels: 2, bitrate: 192000 };
  if ((await AudioEncoder.isConfigSupported(opus).catch(() => null))?.supported) return { config: opus, muxCodec: "opus" };
  return null;
}

/** Every sound track laid along the edit — each clip's stretch, at its speed — and mixed. */
export async function mix(packagePath: string, t: Timeline, tracks: { path: string; gain: number }[], length: number): Promise<AudioBuffer> {
  const rate = 48000;
  const ctx = new OfflineAudioContext(2, Math.max(1, Math.ceil(length * rate)), rate);
  for (const track of tracks) {
    const data = await fetch(fileUrl(packagePath, track.path)).then((r) => r.arrayBuffer());
    const buffer = await ctx.decodeAudioData(data);
    const gain = ctx.createGain();
    gain.gain.value = track.gain;
    gain.connect(ctx.destination);
    let elapsed = 0;
    for (const clip of t.clips) {
      const d = clipDuration(clip);
      if (clip.hold === undefined && clip.sourceStart < buffer.duration) {
        const src = ctx.createBufferSource();
        src.buffer = buffer;
        src.playbackRate.value = clip.speed;
        src.connect(gain);
        src.start(elapsed, clip.sourceStart, Math.min(clip.sourceDuration, buffer.duration - clip.sourceStart));
      }
      elapsed += d;
    }
  }
  return ctx.startRendering();
}

async function encodeAudio(buffer: AudioBuffer, config: AudioEncoderConfig, muxer: Muxer<StreamTarget>) {
  let failure: unknown = null;
  let outputs = 0;
  const encoder = new AudioEncoder({
    output: (chunk, meta) => {
      outputs++;
      muxer.addAudioChunk(chunk, meta);
    },
    error: (e) => (failure = e),
  });
  encoder.configure(config);
  const frames = 4800;
  const left = buffer.getChannelData(0);
  const right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : left;
  for (let start = 0; start < buffer.length; start += frames) {
    const n = Math.min(frames, buffer.length - start);
    const planar = new Float32Array(n * 2);
    planar.set(left.subarray(start, start + n), 0);
    planar.set(right.subarray(start, start + n), n);
    const data = new AudioData({ format: "f32-planar", sampleRate: buffer.sampleRate, numberOfFrames: n, numberOfChannels: 2, timestamp: Math.round((start / buffer.sampleRate) * 1e6), data: planar });
    encoder.encode(data);
    data.close();
    if (failure) throw failure;
    while (encoder.encodeQueueSize > 20 && !failure) await dequeued(encoder);
  }
  await encoder.flush();
  encoder.close();
  if (failure) throw failure;
}
