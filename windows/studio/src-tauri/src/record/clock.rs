//! The take's one clock — the Mac's `RecordingClock`. Every file and every sample is
//! stamped against it:
//!
//! - It starts at the first frame's own timestamp, not when the frame arrives.
//! - It leaves every pause out, for the picture, the sound and the pointer alike.
//!
//! Times are in 100-nanosecond ticks of the performance counter, the base Windows'
//! capture stamps its frames with (`SystemRelativeTime`).

use std::sync::Mutex;

pub const TICKS_PER_SECOND: i64 = 10_000_000;

#[derive(Default)]
struct State {
    start: Option<i64>,
    paused_total: i64,
    pause_started: Option<i64>,
}

#[derive(Default)]
pub struct Clock {
    state: Mutex<State>,
}

impl Clock {
    /// Now, in ticks on the system's clock.
    pub fn now() -> i64 {
        system_ticks()
    }

    /// Starts the clock at the first frame's timestamp; later calls do nothing.
    pub fn start_at(&self, ticks: i64) {
        let mut state = self.state.lock().unwrap();
        if state.start.is_none() {
            state.start = Some(ticks);
        }
    }

    pub fn has_started(&self) -> bool {
        self.state.lock().unwrap().start.is_some()
    }

    pub fn pause(&self) {
        let mut state = self.state.lock().unwrap();
        if state.pause_started.is_none() {
            state.pause_started = Some(system_ticks());
        }
    }

    /// Resumes; returns how long the pause was, in ticks.
    pub fn resume(&self) -> i64 {
        let mut state = self.state.lock().unwrap();
        match state.pause_started.take() {
            Some(began) => {
                let length = (system_ticks() - began).max(0);
                state.paused_total += length;
                length
            }
            None => 0,
        }
    }

    pub fn is_paused(&self) -> bool {
        self.state.lock().unwrap().pause_started.is_some()
    }

    /// Where a system time falls on the take, in ticks: `None` before the start or
    /// during a pause.
    pub fn take_time(&self, system: i64) -> Option<i64> {
        let state = self.state.lock().unwrap();
        let start = state.start?;
        if let Some(began) = state.pause_started {
            if system >= began {
                return None;
            }
        }
        let t = system - start - state.paused_total;
        (t >= 0).then_some(t)
    }

    /// How much has been recorded so far, in seconds.
    pub fn recorded_seconds(&self) -> Option<f64> {
        let state = self.state.lock().unwrap();
        let start = state.start?;
        let end = state.pause_started.unwrap_or_else(system_ticks);
        Some((end - start - state.paused_total).max(0) as f64 / TICKS_PER_SECOND as f64)
    }
}

#[cfg(windows)]
fn system_ticks() -> i64 {
    use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
    let mut count = 0i64;
    let mut frequency = 1i64;
    unsafe {
        QueryPerformanceCounter(&mut count).ok();
        QueryPerformanceFrequency(&mut frequency).ok();
    }
    ((count as i128 * TICKS_PER_SECOND as i128) / frequency.max(1) as i128) as i64
}

#[cfg(not(windows))]
fn system_ticks() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    (SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() / 100) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaves_pauses_out() {
        let clock = Clock::default();
        assert_eq!(clock.take_time(100), None);
        clock.start_at(1_000);
        clock.start_at(5_000); // only the first frame starts it
        assert_eq!(clock.take_time(1_500), Some(500));
        {
            let mut state = clock.state.lock().unwrap();
            state.pause_started = Some(2_000);
        }
        assert_eq!(clock.take_time(2_500), None);
        {
            let mut state = clock.state.lock().unwrap();
            state.pause_started = None;
            state.paused_total = 1_000;
        }
        assert_eq!(clock.take_time(3_500), Some(1_500));
    }
}
