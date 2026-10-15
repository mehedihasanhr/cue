//! Sound for a take: what the PC plays (WASAPI loopback on the default speakers) and a
//! microphone, each written to its own WAV in the package's `media/` folder, as the Mac
//! writes `system-audio.m4a` and `microphone-N.m4a`.
//!
//! Two rules keep the sound in step with the picture, both from the take's clock:
//! - Loopback delivers nothing while nothing plays, so silence is written for every
//!   stretch the clock says has passed without sound.
//! - A pause writes nothing, and the clock leaves the pause out, so the file runs on
//!   from where it stopped.

use super::clock::Clock;
use anyhow::{Context, Result};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: u16 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// What the speakers play.
    System,
    /// The default microphone, or one by its device id.
    Microphone,
}

pub struct AudioRecorder {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<Result<()>>>,
}

impl AudioRecorder {
    /// Starts writing `source` to `path` once the clock has started.
    pub fn start(source: Source, device_id: Option<String>, path: PathBuf, clock: Arc<Clock>) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        let thread = std::thread::Builder::new()
            .name(format!("klik-audio-{source:?}"))
            .spawn(move || run(source, device_id, path, clock, flag))
            .context("Could not start the sound recorder")?;
        Ok(Self { stop, thread: Some(thread) })
    }

    /// Stops and finishes the file.
    pub fn finish(mut self) -> Result<()> {
        self.stop.store(true, Ordering::SeqCst);
        match self.thread.take().map(|t| t.join()) {
            Some(Ok(result)) => result,
            Some(Err(_)) => anyhow::bail!("The sound recorder stopped unexpectedly"),
            None => Ok(()),
        }
    }
}

#[cfg(windows)]
fn run(source: Source, device_id: Option<String>, path: PathBuf, clock: Arc<Clock>, stop: Arc<AtomicBool>) -> Result<()> {
    use std::collections::VecDeque;
    use wasapi::{DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};

    wasapi::initialize_mta().ok().ok();
    let enumerator = DeviceEnumerator::new().map_err(|e| anyhow::anyhow!("{e}"))?;
    let device = match (source, device_id) {
        (Source::System, _) => enumerator.get_default_device(&Direction::Render),
        (Source::Microphone, Some(id)) => enumerator.get_device(&id),
        (Source::Microphone, None) => enumerator.get_default_device(&Direction::Capture),
    }
    .map_err(|e| anyhow::anyhow!("No sound device: {e}"))?;
    let mut client = device.get_iaudioclient().map_err(|e| anyhow::anyhow!("{e}"))?;
    // 32-bit float at 48 kHz, stereo: Windows converts whatever the device runs at.
    let format = WaveFormat::new(32, 32, &SampleType::Float, SAMPLE_RATE as usize, CHANNELS as usize, None);
    let block = format.get_blockalign() as usize;
    let (_, min_period) = client.get_device_period().map_err(|e| anyhow::anyhow!("{e}"))?;
    let mode = StreamMode::EventsShared { autoconvert: true, buffer_duration_hns: min_period };
    // A render device opened for capture is loopback: what it plays.
    client.initialize_client(&format, &Direction::Capture, &mode).map_err(|e| anyhow::anyhow!("{e}"))?;
    let event = client.set_get_eventhandle().map_err(|e| anyhow::anyhow!("{e}"))?;
    let capture = client.get_audiocaptureclient().map_err(|e| anyhow::anyhow!("{e}"))?;

    let spec = hound::WavSpec { channels: CHANNELS, sample_rate: SAMPLE_RATE, bits_per_sample: 32, sample_format: hound::SampleFormat::Float };
    let mut writer = hound::WavWriter::create(&path, spec).context("Could not create the sound file")?;
    let mut queue: VecDeque<u8> = VecDeque::new();
    // Frames written so far, against the clock's idea of how many there should be.
    let mut written: u64 = 0;
    client.start_stream().map_err(|e| anyhow::anyhow!("{e}"))?;

    let write_frames = |writer: &mut hound::WavWriter<_>, bytes: &[u8], written: &mut u64| -> Result<()> {
        for sample in bytes.chunks_exact(4) {
            writer.write_sample(f32::from_le_bytes([sample[0], sample[1], sample[2], sample[3]]))?;
        }
        *written += (bytes.len() / block) as u64;
        Ok(())
    };

    while !stop.load(Ordering::SeqCst) {
        // Waiting for the sound to start is a timeout, not an error: silent loopback
        // sends nothing at all.
        event.wait_for_event(50).ok();
        queue.clear();
        capture.read_from_device_to_deque(&mut queue).ok();
        let Some(now) = clock.recorded_seconds() else { continue }; // not started yet
        if clock.is_paused() {
            continue;
        }
        let expected = (now * SAMPLE_RATE as f64) as u64;
        let incoming = (queue.len() / block) as u64;
        // Fill what passed in silence, leaving room for what just arrived.
        if expected > written + incoming + (SAMPLE_RATE as u64 / 50) {
            let missing = expected - written - incoming;
            let silence = vec![0u8; missing as usize * block];
            write_frames(&mut writer, &silence, &mut written)?;
        }
        let (front, back) = queue.as_slices();
        let mut all = Vec::with_capacity(front.len() + back.len());
        all.extend_from_slice(front);
        all.extend_from_slice(back);
        write_frames(&mut writer, &all, &mut written)?;
    }
    client.stop_stream().ok();
    writer.finalize().context("Could not finish the sound file")?;
    Ok(())
}

#[cfg(not(windows))]
fn run(_: Source, _: Option<String>, _: PathBuf, _: Arc<Clock>, _: Arc<AtomicBool>) -> Result<()> {
    anyhow::bail!("Recording sound needs Windows")
}

/// The microphones Windows knows, as (id, name), the default first.
#[cfg(windows)]
pub fn microphones() -> Vec<(String, String)> {
    use wasapi::{DeviceEnumerator, Direction};
    wasapi::initialize_mta().ok().ok();
    let Ok(enumerator) = DeviceEnumerator::new() else { return Vec::new() };
    let default = enumerator.get_default_device(&Direction::Capture).ok().and_then(|d| d.get_id().ok());
    let mut list: Vec<(String, String)> = enumerator
        .get_device_collection(&Direction::Capture)
        .map(|collection| {
            collection
                .into_iter()
                .flatten()
                .filter_map(|d| Some((d.get_id().ok()?, d.get_friendlyname().ok()?)))
                .collect()
        })
        .unwrap_or_default();
    list.sort_by_key(|(id, _)| Some(id) != default.as_ref());
    list
}

#[cfg(not(windows))]
pub fn microphones() -> Vec<(String, String)> {
    Vec::new()
}
