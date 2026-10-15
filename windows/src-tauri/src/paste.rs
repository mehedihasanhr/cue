//! Paste: what a card's Paste does — put it on the clipboard, then press Ctrl+V in the
//! app that was in front. The island never takes the foreground unless its search field
//! is clicked, so that app is usually still in front; when the island did take it, the
//! window it took it from is remembered and given back first.

use std::sync::Mutex;

static FRONT: Mutex<isize> = Mutex::new(0);

/// Called as the island takes the keyboard: the window to give it back to.
pub fn remember_front() {
    #[cfg(windows)]
    unsafe {
        let window = windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow();
        *FRONT.lock().unwrap() = window.0 as isize;
    }
}

/// The island has closed without pasting: nothing to give back.
pub fn forget_front() {
    *FRONT.lock().unwrap() = 0;
}

/// Gives the keyboard back to the remembered window, waits for it, and presses Ctrl+V.
/// Returns false where it can't (anywhere but Windows).
pub fn press_paste() -> bool {
    #[cfg(windows)]
    unsafe {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL,
        };
        use windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow;
        let front = std::mem::take(&mut *FRONT.lock().unwrap());
        if front != 0 {
            SetForegroundWindow(HWND(front as *mut _)).ok().ok();
        }
        // A moment for the island's own windows to let go and the clipboard to settle.
        std::thread::sleep(std::time::Duration::from_millis(120));
        let key = |vk: VIRTUAL_KEY, up: bool| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: vk, wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, time: 0, dwExtraInfo: 0 },
            },
        };
        let v = VIRTUAL_KEY(0x56);
        let inputs = [key(VK_CONTROL, false), key(v, false), key(v, true), key(VK_CONTROL, true)];
        return SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) == inputs.len() as u32;
    }
    #[cfg(not(windows))]
    false
}
