//! The capture sound: the Mac's own shutter, played without waiting for it.

#[cfg(windows)]
pub fn shutter() {
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT};
    static SHUTTER: &[u8] = include_bytes!("../resources/shutter.wav");
    // SND_MEMORY reads the WAV from this pointer; `SHUTTER` lives for the whole program.
    unsafe {
        let _ = PlaySoundW(
            windows::core::PCWSTR(SHUTTER.as_ptr() as *const u16),
            None,
            SND_MEMORY | SND_ASYNC | SND_NODEFAULT,
        );
    }
}

#[cfg(not(windows))]
pub fn shutter() {}
