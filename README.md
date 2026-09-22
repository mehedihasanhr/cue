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

Defaults: **⌥⇧3** full screen · **⌥⇧4** area · **⌥⇧6** window · **⌥⇧5** scrolling · **⌥⇧T** capture
text · **⌥⇧P** pick a color · **⌥⇧N** quick task · **⌥⇧M** quick note · **⌥⇧K** the Klik panel ·
**⌘⇧C** the clipboard list (type to filter, ↑↓, ↩ pastes, ⌘↩ copies, ⌥↩ pastes as
plain text, ⇧↑↓ picks several to paste joined, ⌘1–9 picks) · **⌥⇧Space** the command
palette · **⌘⇧V** the paste stack (each press pastes the next entry of the history).
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

### Window capture (⌥⇧6)

Hover lights up the window under the pointer; a click captures it by itself, with its
shadow, on a transparent background (a drag still selects an area). For a device-frame
look, open it in the editor and use the Background tool.

### Text in captures

Every capture's text is read (on-device, in the background) when it is saved — older
ones catch up shortly after launch — so "search everything" finds the screenshot that
held the error message. "Capture text" keeps code's indentation, and right-clicking a
text entry on the Clipboard tab offers **Extract** › URLs / e-mail addresses / numbers.

### Palette from a capture

Right-click a capture › **Palette**: keep its six dominant colors in the Colors tab, or
copy them as CSS variables, Tailwind colors or SwiftUI.

### Writing a task

A task is one text, not a title and a description: lists show its first line, plain.
The editor shows Markdown as what it means while you type — `# ` starts a heading,
`- ` a bullet, `1. ` a numbered list, `[ ] ` in a bullet a checkbox, `> ` a quote,
```` ``` ```` a code block, and `**bold**`, `*italic*`, `` `code` `` or `~~struck~~`
turn into the style as they close. `/` lists every format, `#` picks a project, `!` a
priority, all from the keyboard; a pick shows in the buttons under the text and the
token goes. What is saved is still Markdown. The floating pane (⌥/) moves by the
strip along its top, so a drag in the text selects.

### Tasks from captures, focus sessions

Right-click a capture › **Make Task…** opens the task form with the screenshot
attached. Right-click a task › **Focus** › 15/25/45/60 minutes starts a session: the
island's header shows a ring and the time left (click it to open the task, ■ to stop),
and it says so with a sound when the time is up.

### Preview pane

A card's eye opens it in the cards' place — or, with Settings › Island › **Preview
opens › Below it**, in a pane under the island while the cards stay: an image at
full width, a color as a band with every format (click one to copy it, the Copy
button's menu has them too), a link with the page's picture, title and summary,
text in full. The pane counts as part of the island for the pointer.

### Quick notes

**⌥⇧M** (or Notes › New in the island, or `klik://note`) opens a note at the pointer:
Markdown, the first line is the title, `/` for formatting, images pasted or dropped in;
**⌘↩** saves. Each note is one `.md` file named after its title, in Klik's own folder
or — Settings › Notes › Choose… — any folder: one in iCloud Drive syncs the notes with
your other devices, an Obsidian vault folder shows them in Obsidian. The folder is
watched, so notes edited elsewhere (Obsidian, another Mac) show up in the island. Only
the folder's top level is read; images go in `attachments/` beside the notes.

Saving can also put a new note in **Obsidian** (through its `obsidian://new` link;
name the vault in Settings, else the last one opened), **Apple Notes** (in the folder
named in Settings; macOS asks once to let Klik control Notes) or **Notion** (an
internal integration's secret and the page or database to put pages under; the secret
stays in the Keychain; headings, lists, to-dos, quotes and code become the matching
blocks). Settings › Notes › **Send new notes to…** sets the defaults; the form's
**Save as** menu changes them for one note ("Klik only" keeps it in the folder). A
card's menu sends an existing note anywhere later.

### Sync folder

Settings › General › Sync: keep snippets, colors and tasks as JSON in a folder of your
own — one in iCloud Drive or Dropbox shares them with your other Macs — and Klik
reloads when the files change. Task attachments stay on each Mac.

### Pin a capture to the screen

"Pin to Screen" on a capture (or ⌘P in the palette) floats it above every window to
work against: drag it anywhere, ⌘= / ⌘- or ⌥-scroll to resize, hover for copy / close /
ghost (half see-through and click-through; double-click, or the palette's "Unghost
pinned screenshots", brings it back), ⎋ closes.

### Share links

Settings › Sharing: an **S3-compatible bucket** (AWS S3, Cloudflare R2, MinIO, B2 —
signed on-device, PUT with public-read) or a **custom endpoint** (PUT raw PNG or POST
multipart, an optional auth header, the link read from the answer). Then "Copy Share
Link" on a capture, or ⌘L in the palette, uploads it and puts the link on the
clipboard. Secrets are kept in the Keychain.

### Code on the clipboard

Text that reads as code is badged with its language and line count and lightly
highlighted on its card; "Copy as Code Block" / "Paste as Code Block" wrap it in a
Markdown fence with the right language.

### Images on the clipboard

An image you copied anywhere can be edited like a capture: the pencil on its
card in the island, or "Edit…" in its menu (also in the ⌘⇧C panel), saves it
with your captures and opens it in the editor — annotate, blur, crop — and Done
puts the result back on the clipboard.

### URL scheme and command line

`klik://` URLs drive Klik from Shortcuts, Raycast, Alfred, a browser or a script:
`klik://capture/area|window|full|scrolling|text`, `klik://color/pick`,
`klik://task/new?title=…&notes=…&priority=high&project=…`, `klik://note/new?text=…`,
`klik://snippet/add?keyword=;sig&text=…`, `klik://clipboard/copy?text=…`,
`klik://palette`, `klik://clipboard`, `klik://panel`, `klik://clock`, `klik://settings`.
`Tools/klik` wraps them for the shell (`klik capture area`, `klik task "Fix it" -p high`,
`klik copy "text"`, `echo hi | klik copy`); run `chmod +x Tools/klik` and put it on your
PATH, or call it as `sh Tools/klik …`.

### Snippets (text expander)

The island's **Snippets** tab. Give a snippet a keyword (`;welcome`) and a template;
type the keyword in any app and Klik replaces it with the template. `{{Name}}` in the
template is a blank Klik asks for before pasting (in the island's compact box);
`{{date}}`, `{{time}}`, `{{datetime}}` and `{{clipboard}}` fill themselves. A snippet
can paste an asset (an image or a file) instead of text. Make one with **New** in the
tab, or from a clipboard entry or an asset with **Make Snippet…** in its menu. Needs
Accessibility access (Settings › Island › Snippets); what was on the clipboard is put
back after the paste.

Built-ins: `{{date}}`, `{{time}}`, `{{datetime}}`, `{{clipboard}}`, `{{uuid}}`,
`{{date:yyyy-MM-dd}}` / `{{time:HH:mm}}` (any Unicode date format), `{{cursor}}` (where the
caret lands after the paste) and `{{shell:git branch --show-current}}` (what a command
prints, given two seconds, inside Klik's sandbox).

### Time & prayer times

Settings › Time (the switch at the top right turns the whole clock off; Snippets and
Colors have one too). The island shows the time for a moment on the hour (or every
15 / 30 minutes, 2 or 3 hours — or never); it waits while the island is open. Turn on **Prayer
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
├── Notes/        NoteStore (Markdown files, the folder watched), NoteForm, NoteCard,
│                 NoteSharing (Obsidian, Apple Notes, Notion)
├── Permissions/  PermissionManager, OnboardingView
├── Preview/      Temporary capture viewer (replaced by the editor in Step 3)
├── Support/      CapturedImage, Log, WindowHosting, Icon (the island's Hugeicons stroke icons,
│                 by SF Symbol name; HugeIconGlyphs is generated from @hugeicons/core-free-icons, MIT)
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
