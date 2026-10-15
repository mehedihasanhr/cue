# Klik for Windows

Klik for Windows is the screenshot tool in the Windows tray. It is built with Tauri 2: a Rust core (`windows/src-tauri`) and a React + TypeScript UI (`windows/src`). It shares no code with the Mac app, but follows it closely:

- the same capture overlay
- the same editor tools and shape recognizer, ported line for line with the Mac's test cases
- the same file names
- the same `library.json` fields

## What it does (0.2)

| Feature | How |
| --- | --- |
| Capture area, window, full screen | Every display is frozen first, then you choose. Window snapping, a loupe, Shift for a square, Ctrl to turn snapping off, Ctrl+A for the whole display, Esc to cancel. |
| Capture text | Windows' own OCR (`Windows.Media.Ocr`) in your installed languages. The text goes to the clipboard. |
| Editor | Arrow (bendable, single or double), rectangle, ellipse, line, pencil with smart shapes, highlighter, highlight box, text, counter, blur and pixelate. Also crop, rotate, a background (gradients, colours, padding, inset, corners, shadow, ratio), undo and redo, copy, Save As PNG or JPEG. |
| Dynamic Island | A black pill hanging from the top centre of each display, drawn and animated like the Mac's. Hover (or click) and it opens into the Klik panel: search, the capture buttons, and today's captures. New captures flash on it; copies, uploads and errors show as statuses. Closed, it lets every click through. |
| Klik panel | The Mac's floating panel (Alt+Shift+K, or a left click on the tray icon), opened where Settings › Island › Panels says. Every capture by day, with search. Edit, copy, copy share link, float on screen, show in Explorer, pin to top, rename, and delete to the Recycle Bin. |
| Float on screen | The capture stays above other windows. Drag to move, scroll to resize, right-click for opacity, Esc to close. |
| Share link | Uploads to an S3-compatible bucket (signed on the PC) or a custom endpoint, then copies the link. Secrets are kept in Windows Credential Manager. |
| Settings | The Mac's layout: a sidebar with search, back and forward, and pages for General, Appearance, Shortcuts, Sharing, About, Island, Capture and Editor (every editor default, or "remember last used"). Mica behind it on Windows 11. |
| Tray, shortcuts, sign-in | Tray menu. Global shortcuts you can rebind. Option to open at sign-in. A shutter sound after each capture. Updates from the releases repo. |

Default shortcuts mirror the Mac's ⌥⇧ set as **Alt+Shift**:

| Shortcut | Action |
| --- | --- |
| Alt+Shift+4 | Area |
| Alt+Shift+6 | Window |
| Alt+Shift+3 | Full screen |
| Alt+Shift+T | Text |
| Alt+Shift+K | Klik panel at the pointer |

From a script or another launcher:

- `klik.exe --capture area|window|fullscreen|text` takes a capture.
- `klik.exe --open history|settings` opens the Klik panel or Settings; `--open settings/island` (or any page name) opens Settings on that page.

### Where things are kept

| What | Where |
| --- | --- |
| Captures | `%USERPROFILE%\Pictures\Klik\Screenshot yyyy-MM-dd at HH.mm.ss.png` |
| Settings | `%APPDATA%\Klik\settings.json` |
| History index and thumbnails | `%LOCALAPPDATA%\Klik\` |
| Secrets | Windows Credential Manager, under "Klik" |

## Building

Prerequisites: Node 22+ and pnpm, and Rust stable.

```sh
cd windows
pnpm install
pnpm lint && pnpm test                       # type-check and UI tests
(cd src-tauri && cargo test --lib)           # Rust tests (settings, library, geometry, SigV4)
```

**On Windows:** `pnpm tauri dev` runs the app, and `pnpm tauri build` makes the installer.

**On a Mac:** you can type-check against Windows and build the real installer by cross-compiling.

1. Install the tools once:

   ```sh
   brew install llvm nsis
   cargo install --locked cargo-xwin
   rustup target add x86_64-pc-windows-msvc
   ```

2. Check against the Windows target:

   ```sh
   (cd src-tauri && PATH="/opt/homebrew/opt/llvm/bin:$PATH" cargo check --target x86_64-pc-windows-msvc)
   ```

3. Build the installer:

   ```sh
   bash scripts/build-installer.sh
   ```

   It goes to `src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/`.

CI (`.github/workflows/windows.yml`) runs the same checks on `windows-latest` and attaches the installer to the run.

## Releasing

1. Bump `version` in `windows/src-tauri/tauri.conf.json` and `windows/package.json`.
2. Build with `bash windows/scripts/build-installer.sh`. It signs the update with `~/.tauri/klik-windows.key`. Keep that key safe: without it, installed copies can never update again.
3. Publish with `bash windows/scripts/publish-release.sh`. This:
   - creates `windows-<version>` on `mehedihasanhr/klik-releases`, never marked latest
   - replaces `latest.json` on the `windows-feed` release, which is what the in-app updater reads

The installer isn't code-signed, so Windows SmartScreen shows "Windows protected your PC". Users choose **More info › Run anyway**.

## Testing on a PC (checklist)

- [ ] The installer runs, Klik appears in the tray, and a left click on it opens the Klik panel.
- [ ] Island: the pill shows at the top centre of every display and never blocks clicks on a maximised window's title bar. Hovering opens it; leaving closes it. A capture flashes on it. Typing in its search works.
- [ ] Alt+Shift+4: the overlay covers every display. The loupe follows the pointer, and hovering a window outlines it.
- [ ] Drag an area: the saved PNG is exactly that area, also with two displays at different scaling (100% and 150%).
- [ ] Click a window in Window mode: you get that window's frame.
- [ ] Esc cancels on any display.
- [ ] Alt+Shift+3 captures the display under the pointer.
- [ ] Paste into Paint and into a browser after a capture.
- [ ] Editor:
  - [ ] Every tool draws, and selecting, moving, resizing and rotating work.
  - [ ] Undo and redo work.
  - [ ] Crop applies with Enter.
  - [ ] The background panel works.
  - [ ] Copy, Save As (PNG and JPEG) and Done all work.
- [ ] A rough rectangle, circle, line and arrow drawn with the pencil turn into clean shapes.
- [ ] Alt+Shift+T on some text: the text lands on the clipboard and the island says so.
- [ ] Klik panel: rename (F2), delete goes to the Recycle Bin, Show in Explorer, and a floating window that you can drag, scroll and set the opacity of.
- [ ] Settings: rebinding a shortcut works at once. A taken shortcut is flagged. "Open at sign-in" survives a restart. Island settings change the island at once. Editor defaults reach the next editor.
- [ ] Sharing with an S3 bucket or endpoint copies a working link.
- [ ] Settings › About › Check for Updates finds a newer test release.
