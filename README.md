# Klik

A native macOS screenshot tool in the spirit of CleanShot X — SwiftUI + AppKit, ScreenCaptureKit,
sandboxed, no third-party dependencies. macOS 14+.

**Status: capture + settings done, editor next.** Menu-bar agent with its own global
shortcuts (⌥⇧3 full screen · ⌥⇧4 area · ⌥⇧5 scrolling, all rebindable), area-selection
overlay with magnifier / handles / window snapping, scrolling capture with automatic
stitching, permission onboarding, Settings window (shortcuts, launch at login).

## Requirements

- Xcode 26 (Swift 6, Approachable Concurrency, main-actor-by-default)
- macOS 14 Sonoma or later

## Build

```sh
# Command line
xcodebuild -project Klik.xcodeproj -scheme Klik -configuration Debug build
open build/Debug/Klik.app

# or just open Klik.xcodeproj in Xcode and press ⌘R
```

### Code signing

macOS ties the Screen Recording grant to the app's code signature, so the dev build
needs a *stable* identity — an ad-hoc signature changes on every build and the grant
silently stops matching (the toggle in System Settings stays on, but the app is
treated as un-granted). `Config/Signing.xcconfig` (git-ignored) picks one of:

- **Local certificate (default)** — a self-signed "Klik Development" code-signing
  certificate in your login keychain. Create it once:

  ```sh
  # generate (files land in Config/local/, git-ignored)
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Klik Development/O=Klik local build" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout Config/local/klik-dev.key -out Config/local/klik-dev.pem
  openssl pkcs12 -export -legacy -inkey Config/local/klik-dev.key -in Config/local/klik-dev.pem \
    -out Config/local/klik-dev.p12 -passout pass:klik -name "Klik Development"
  # import + trust for code signing (approve the macOS dialogs)
  security import Config/local/klik-dev.p12 -k ~/Library/Keychains/login.keychain-db -P klik -T /usr/bin/codesign
  security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db Config/local/klik-dev.pem
  ```

- **Apple ID** — sign into Xcode › Settings › Accounts (a free Personal Team is enough)
  and paste the Team ID into `DEVELOPMENT_TEAM =` in the xcconfig.

If a grant ever gets stuck, clear it and re-grant: `tccutil reset ScreenCapture com.stackrover.klik`.

## First run

1. Launch Klik. A camera icon appears in the menu bar (no Dock icon) and, because the
   permission is missing, the onboarding window opens.
2. Click **Request Access**, then **Open System Settings** in the system prompt and turn
   on **Klik** under Privacy & Security › Screen & System Audio Recording.
3. Back in Klik, click **Relaunch Klik** — macOS applies the grant on the next launch.
4. Press **⌥⇧3** (full screen), **⌥⇧4** (area) or **⌥⇧5** (scrolling), or hover the
   notch to open the Dynamic Island and use its capture buttons. Captures open in a
   preview window at native Retina resolution. The menu bar icon only holds Settings
   and Quit.

### Area capture (⌥⇧4)

The screen freezes under a dimmed overlay. Drag to select (⇧ = square, ⌘ = no
snapping), or click a window to select it. Edges snap to nearby windows. After
releasing: drag the handles to resize, drag inside to move, arrow keys nudge
(⇧ = 10 pt, ⌥ = resize). **↩** or the Capture button confirms, **⎋** cancels, **⌘A**
selects the whole screen. The loupe shows pixel coordinates and the colour under the
cursor.

### Scrolling capture (⌥⇧5)

Select the scrolling area the same way, then click **Start Scrolling Capture**. Klik
scrolls the content underneath step by step, captures each viewport, and stitches the
frames (sticky headers/footers are removed). It stops at the end of the content, or
when you press **⎋** / **Stop** in the floating HUD. Requires the **Accessibility**
permission (Klik asks on first use) so it can send scroll events to the target app.

### Shortcuts

Defaults: **⌥⇧3** full screen · **⌥⇧4** area · **⌥⇧5** scrolling · **⌥⇧T** capture
text · **⌥⇧P** pick a color · **⌥⇧N** quick task · **⌥⇧K** the Klik panel ·
**⌘⇧C** the clipboard list (type to filter, ↑↓, ↩ pastes, ⌘↩ copies, ⌥↩ pastes as
plain text, ⌘1–9 picks) · **⌥⇧Space** the command palette.
Klik › Settings › Shortcuts: click a field and press a new combination (⌫ clears).
The macOS defaults (⌘⇧3/4/5/6) are handled by the system first; Klik marks them with a
warning if you bind them, and links to Keyboard › Keyboard Shortcuts › Screenshots
where they can be turned off.

### Command palette (⌥⇧Space)

One list over everything, driven by the keyboard: Klik's actions (capture area, pick a
color, new task…), quick answers, and every capture, clipboard entry, asset, color,
task and snippet. Type to filter, ↑↓ to choose, **↩** pastes the item where the cursor
was (or runs the action / opens a task), **⌘↩** copies, **⌘O** opens (edit a capture,
open an asset, edit a snippet), ⌘1–9 pick, ⎋ closes.

### Quick answers

The island search and the palette work some things out on the spot and show them as
cards to copy: a color in every format (`#0E4FEC`, `ff8800`), a Unix timestamp as a
date (`1700000000`), hex ↔ decimal ↔ binary (`0x1F`, `255`, `0b1010`), px ↔ rem
(`256px`, `1.5rem`), base64 (`b64 hello`, or paste base64 to decode), a sum
(`(3+4)/2`, `2^10`), `uuid`, `now`.

### Paste as…

Right-click a text entry on a clipboard card or in the clipboard list for **Paste as** /
**Copy as**: plain text, trimmed, one line, lower/UPPER/Title/Sentence case, camelCase,
snake_case, kebab-case, pretty or minified JSON, URL-encoded/decoded, Markdown → plain
text, quoted. Only the transforms that would change the text are listed.

### Snippets (text expander)

The island's **Snippets** tab. Give a snippet a keyword (`;welcome`) and a template;
type the keyword in any app and Klik replaces it with the template. `{{Name}}` in the
template is a blank Klik asks for before pasting (in the island's compact box);
`{{date}}`, `{{time}}`, `{{datetime}}` and `{{clipboard}}` fill themselves. A snippet
can paste an asset (an image or a file) instead of text. Make one with **New** in the
tab, or from a clipboard entry or an asset with **Make Snippet…** in its menu. Needs
Accessibility access (Settings › Island › Snippets); what was on the clipboard is put
back after the paste.

### Time & prayer times

Settings › Time. The island shows the time for a moment on the hour (or every 15 / 30
minutes, 2 or 3 hours — or never); it waits while the island is open. Turn on **Prayer
times** and the island announces each prayer as it begins and the three periods when
prayer is not allowed (after sunrise, at the sun's zenith, before sunset); the open
island shows the current period and what is left of it. Times are computed on the Mac
from the sun's position at your location (Core Location, or coordinates entered by
hand) with the usual calculation methods (Muslim World League, ISNA, Egyptian, Umm
al-Qura, Karachi, Dubai, Kuwait, Qatar, Singapore, Turkey) and Standard or Hanafi Asr.
Nothing is fetched from the internet; they refresh at midnight, on wake and when the
location changes.

### Launch at login

Klik › Settings › General › **Launch Klik at login** (uses `SMAppService`; macOS may ask
you to approve it under General › Login Items).

## Logs

```sh
/usr/bin/log stream --level info --predicate 'subsystem == "com.stackrover.klik"'
```

## Layout

```
Klik/
├── App/          KlikApp (@main), AppDelegate, MainMenu, HotkeyManager (Carbon), ShortcutController,
│                 ShortcutRecorderView, KeyCodeNames, AppModel, SettingsView, LaunchAtLogin
├── Capture/      CaptureCoordinator, ScreenCaptureService (ScreenCaptureKit), CaptureSession,
│                 OverlayWindow, SelectionView, MagnifierView, SelectionToolbar, WindowDetector
│   └── Scrolling/  ScrollingCaptureService, AccessibilityScroller, FrameStitcher, ScrollingHUD
├── Editor/       (Step 3–4)
├── Export/       (Step 5)
├── Permissions/  PermissionManager, OnboardingView
├── Preview/      Temporary capture viewer (replaced by the editor in Step 3)
├── Support/      CapturedImage, Log, WindowHosting
└── Resources/    Assets.xcassets
Config/           Klik.entitlements, Signing.xcconfig (local)
```

The Xcode project uses a file-system-synchronized group, so new files under `Klik/` are
picked up automatically — no project edits needed.

## Roadmap

1. ✅ Scaffold, permissions, full-screen capture
2. ✅ Region capture overlay (drag-select, magnifier, window snapping)
3. Editor skeleton (canvas, zoom/pan, toolbar, undo/redo)
4. Annotation tools (rect, ellipse, arrow, text, pen, highlighter, blur, pixelate, steps)
5. Export (clipboard, save, drag-out, floating thumbnail)
6. ✅ Scrolling capture
7. Polish (✅ custom shortcuts, ✅ preferences window; save locations, dark mode, localization)
