// The recording's frames, decoded on demand for the export: ask for a moment, get the
// frame showing then. Reads forwards through the file as the export does, and only goes
// back to a keyframe when the edit jumps (a cut, a reordered clip).

import { media, type VideoInfo } from "../../lib/ipc";
import { dequeued } from "./codec";

const BATCH = 24;

export class FrameSource {
  private decoder!: VideoDecoder;
  private info!: VideoInfo;
  /** Samples in decode order: presentation time (µs) and whether a decoder can start there. */
  private pts: number[] = [];
  private syncSet = new Set<number>();
  /** Next sample (1-based) to feed. */
  private next = 1;
  private ready: VideoFrame[] = [];
  private current: VideoFrame | null = null;
  private waiting: (() => void) | null = null;
  private failure: Error | null = null;
  private config!: VideoDecoderConfig;

  constructor(private readonly path: string) {}

  async open() {
    this.info = await media.open(this.path);
    const scale = 1e6 / this.info.timescale;
    this.pts = this.info.times.map((t) => t * scale);
    this.syncSet = new Set(this.info.syncs);
    this.config = {
      codec: this.info.codec,
      description: new Uint8Array(this.info.description),
      codedWidth: this.info.width,
      codedHeight: this.info.height,
      optimizeForLatency: false,
    };
    const support = await VideoDecoder.isConfigSupported(this.config);
    if (!support.supported) throw new Error(`This PC can't decode the recording (${this.info.codec}).`);
    this.makeDecoder();
  }

  get width() {
    return this.info.width;
  }
  get height() {
    return this.info.height;
  }

  private makeDecoder() {
    this.decoder = new VideoDecoder({
      output: (frame) => {
        this.ready.push(frame);
        this.wake();
      },
      error: (e) => {
        this.failure = e instanceof Error ? e : new Error(String(e));
        this.wake();
      },
    });
    this.decoder.configure(this.config);
  }

  /** Until the decoder puts out a frame or takes the next chunk (events, not timers). */
  private pause() {
    return Promise.race([new Promise<void>((r) => (this.waiting = r)), dequeued(this.decoder)]);
  }

  private wake() {
    const w = this.waiting;
    this.waiting = null;
    w?.();
  }

  /** The decode-order index (0-based) of the frame shown at `us`. */
  private sampleAt(us: number): number {
    let best = 0;
    let bestPts = -Infinity;
    for (let i = 0; i < this.pts.length; i++) {
      const p = this.pts[i];
      if (p <= us + 500 && p > bestPts) {
        best = i;
        bestPts = p;
      }
    }
    return best;
  }

  /** Starts decoding again from the keyframe before `us`. */
  private restartBefore(us: number) {
    const target = this.sampleAt(us) + 1;
    let start = 1;
    for (const s of this.info.syncs) if (s <= target && s > start) start = s;
    this.decoder.close();
    for (const f of this.ready) f.close();
    this.ready = [];
    this.current?.close();
    this.current = null;
    this.makeDecoder();
    this.next = start;
  }

  private async feed(): Promise<boolean> {
    if (this.next > this.pts.length) {
      if (this.decoder.state === "configured") await this.decoder.flush();
      return false;
    }
    const raw = await media.read(this.path, this.next, BATCH);
    const buffer = raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw as unknown as number[]);
    if (!buffer.length) throw new Error("The recording's picture couldn't be read.");
    let offset = 0;
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    while (offset + 5 <= buffer.length) {
      const sync = buffer[offset] === 1;
      const size = view.getUint32(offset + 1, true);
      const data = buffer.subarray(offset + 5, offset + 5 + size);
      offset += 5 + size;
      const index = this.next - 1;
      this.decoder.decode(new EncodedVideoChunk({ type: sync || this.syncSet.has(this.next) ? "key" : "delta", timestamp: this.pts[index], data }));
      this.next++;
    }
    // Let the decoder catch up rather than queueing the whole file.
    while (this.decoder.decodeQueueSize > BATCH && !this.failure) await this.pause();
    return true;
  }

  /** The frame on screen at `seconds` of the recording. Owned by this source; don't close it. */
  async frameAt(seconds: number): Promise<VideoFrame | null> {
    const us = seconds * 1e6;
    const tolerance = 500;
    const head = this.ready.length ? this.ready[this.ready.length - 1].timestamp : (this.current?.timestamp ?? -Infinity);
    // Gone back, or far ahead past a keyframe: start again from the keyframe before it.
    if ((this.current && us + tolerance < this.current.timestamp) || us - head > 3e6) {
      const needed = this.sampleAt(us) + 1;
      const fromKey = Math.max(...this.info.syncs.filter((s) => s <= needed), 1);
      if (!this.current || us + tolerance < this.current.timestamp || fromKey > this.next) this.restartBefore(us);
    }
    for (;;) {
      if (this.failure) throw this.failure;
      // Move on through the frames that are due.
      while (this.ready.length && this.ready[0].timestamp <= us + tolerance) {
        this.current?.close();
        this.current = this.ready.shift()!;
      }
      if (this.ready.length) return this.current ?? this.ready[0];
      const more = await this.feed();
      if (!more) {
        // Flushed: whatever came out is all there is.
        while (this.ready.length && this.ready[0].timestamp <= us + tolerance) {
          this.current?.close();
          this.current = this.ready.shift()!;
        }
        return this.current ?? this.ready[0] ?? null;
      }
      // Give the decoder a moment to put out what it was given.
      if (!this.ready.length && this.decoder.decodeQueueSize > 0) {
        await this.pause();
      }
    }
  }

  debug() {
    return `dec ${this.decoder.state} q${this.decoder.decodeQueueSize} ready ${this.ready.length} next ${this.next}/${this.pts.length} cur ${this.current?.timestamp}`;
  }

  close() {
    try {
      this.decoder?.close();
    } catch {
      /* already closed */
    }
    for (const f of this.ready) f.close();
    this.current?.close();
    this.ready = [];
    this.current = null;
    media.close(this.path).catch(() => {});
  }
}
