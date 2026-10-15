/**
 * Until the codec takes the next item off its queue. An event rather than a timer: a
 * window in the background has its timers slowed to a crawl, and an export is exactly
 * what someone leaves running while they do something else.
 */
export function dequeued(codec: VideoEncoder | AudioEncoder | VideoDecoder): Promise<void> {
  return new Promise((resolve) => {
    const done = () => {
      codec.removeEventListener("dequeue", done);
      resolve();
    };
    codec.addEventListener("dequeue", done);
    // In case a codec doesn't say: a timer, slow or not, still ends the wait.
    setTimeout(done, 100);
  });
}
