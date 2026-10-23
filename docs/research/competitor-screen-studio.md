<!-- Research gathered 2026-09-29 by a research agent; sources are listed at the end. -->

# Screen Studio competitor research report

Research date: 2026-09-29. Current stable is 3.7.5-4595 (2026-08-05); current beta is 4.0.1-4846.

**Caveats on evidence**
- Reddit, X and G2 could not be read directly (blocked or 403). Reddit sentiment below is second-hand, via AlternativeTo and competitor blogs.
- Many third-party articles are competitor blogs. I flag them as biased and did not treat their claims as fact unless official sources agree.
- The homepage price uses animated digits; the fetch summary misread it as $20. Raw HTML and several third parties confirm $29.
- No processes were started. Raw data is in `/private/tmp/claude-501/-Users-stackrover-Workspaces-offices-stackrover-cue/9c09420c-5547-4a41-bee3-db5b1cfd830c/scratchpad/` (`fb_top_1..6.json` holds all 296 public feature requests; `changelog.txt` holds the full changelog).

## Screen Studio feature inventory

### Recording

**Sources**
- Display: pick a display by clicking it. One display at a time; "record all monitors at once" was rejected.
- Window: click the window, or right-click the Window button for a list. Fullscreen apps should use Display.
- Area: drag or type width/height, with guide lines and a 25/50/75% grid. Dimensions and aspect ratio can be saved; max dimensions are shown.
- Device: iPhone/iPad over USB (USB-C to Lightning recommended; device must be trusted and unlocked). Model and colour are auto-detected, rotation during recording is handled, and iPhone audio is recorded (3.2.0).
- iPhone Mirroring: record the macOS 15+ mirroring window, then apply a device frame in the editor.
- Import: File > "Create project from video" for .mp4 and .mov, with audio. Imported video gets zooms and styling but no cursor effects or webcam.

**Capture behaviour**
- The cursor is not baked into the video. Mouse position, clicks and cursor type are recorded separately and re-rendered, which is what enables post-recording cursor effects (official FAQ).
- Recording appears fixed at 60 fps at native resolution, per an open hub request for a 30 fps option. One review claims a 30/60 option: unverified.
- Ultra-wide recordings are scaled down to avoid encoder crashes.
- Window pre-sizing: precise resize plus size presets. A 2023 review lists 1920x1080 and 9:16 presets and custom pixel input. The recorded window is focused first (needs Accessibility permission).
- Chrome and Safari crop suggestions.

**Audio and camera inputs**
- System audio from all apps or selected apps only (macOS 13+).
- Microphone: device picker with live level bar, stereo support (3.4.7), optional auto-gain disable, warning when the lid-closed mic is muted.
- Camera: device picker, floating preview (the area under it is still recorded), hide preview, full-frame preview before recording.
- Camera formats 720p / 1080p / 4K (3.4.5); ideal webcam fps is 30. Continuity Camera is marked Done on the hub.
- macOS system camera effects (Background, Portrait, Studio Light, Reactions) are used via the menu bar, not implemented in-app.

**Controls during recording**
- Widget with timer, finish, pause/resume (3.2.0), restart and delete. It is hideable and excluded from output on macOS 12.3+.
- Stop via widget, menu bar icon, Dock right-click, or global shortcut. There is a pause shortcut.
- Countdown before recording. A 2023 review says it is customizable; the current options are unverified.
- Recording flags: Cmd+Opt+Ctrl+F drops markers that appear on the timeline (rebindable).
- New-recording modal opens on launch, or with Opt+Cmd+Enter, or from the menu bar icon, which can start each recording type and open projects.

**Environment and safety**
- Hide desktop icons; hide Dock icon (Settings > General); dim the unrecorded area (can be disabled).
- Notifications are suppressed by default; a macOS setting re-enables them.
- Low-disk warnings before and during recording; project recovery if recording fails; extra guards against double recording sessions.
- Permissions requested: Accessibility, Camera, Microphone, Screen Recording.
- Raycast extension commands: record display/window/area, finish, cancel, restart, toggle area cover, toggle controls, open projects folder, open settings, copy-and-zip project. A custom URL scheme exists.

### Cursor

- Hide cursor globally, or per slice (right-click > "Hide mouse cursor").
- Cursor size is adjustable after recording; system cursors are swapped for high-resolution versions.
- Cursor type: macOS or Touch (for iOS recordings).
- Cursor sets: a "large collection" since 3.0, including a macOS Tahoe set (auto-selected on matching OS), system cursor variants, Figma cursors and a Halloween set. Hover preview in the sidebar.
- User-uploaded or brand cursors are not supported (open request, 42 votes).
- Always use default system cursor (no I-beam or pointer switching).
- Optimize cursor type changes (suppresses rapid flicker).
- Hide cursor when idle, with animation.
- Loop cursor position (returns to start near the end for loopable videos).
- Rotate cursor while moving.
- Stop cursor movement at the end of the video.
- Remove cursor shakes (from accessibility tools).
- Smoothing presets: Smooth / Medium / Rapid / None. Per-segment "Disable smooth mouse movement" exists.
- The spring physics sliders (tension, friction, mass) were removed around 2025, per a hub complaint.
- Click effects: ripple, shockwave, circle. The beta reworks Ripple.
- Click sound effects with selectable sound and volume (3.3.0).
- iOS recordings have no cursor or tap data. A Bluetooth mouse shows a system circle, unsmoothed.

### Zoom

- Automatic zooms are generated from recorded clicks. They can be turned off in Settings > Recording > "Create zooms automatically".
- A dedicated zoom timeline shows purple blocks. Click to add; drag edges to change duration. Minimum duration is 0.1 s.
- Modes per zoom: Auto (follows clicks/cursor) or Manual (drag a target dot; the picker shows percentages and snaps to 50%).
- Zoom level is a slider per zoom. Keys 0-9 set the level on hover, and one zoom's level can be applied to all.
- Minimum zoom is 100%; below 100% is an open request (62 votes). Maximum is unverified.
- Instant zoom: "Instant Animation" toggle for no animated transition.
- Disable without deleting, remove, duplicate, copy/paste, Cmd+click multi-select with batch actions.
- Remove all zooms by right-clicking an empty part of the zoom timeline.
- A zoom starting on frame 1 starts the video already zoomed.
- "Always keep zoomed in": crops to the chosen aspect ratio and pans with the cursor. Can be disabled for vertical mode.
- Vertical export re-computes zooms automatically.
- Cutting mid-zoom blends the animation correctly.
- Not available: zoom-on-typing or caret focus (rejected), drag-rectangle zoom selection (rejected), default-to-manual (rejected), auto zoom for iOS recordings.
- Beta 4.0: Glass Loupe effect and sharper zoomed-in text.

### Camera / webcam

- Editor settings: hide camera, position presets, mirror, roundness (square to circle), size, custom aspect ratio, shadow.
- Camera during zoom: shrinks automatically. The shrink amount is adjustable or can be turned off. A 2023 review gives the default as 70%.
- Dynamic camera layouts on their own timeline: Fullscreen camera, Default (camera plus screen, repositionable) and Hidden, with animated transitions.
- The small camera keeps a constant distance to the edge regardless of padding.
- Not available in stable: background blur/removal, camera crop, camera zoom, free keyframed moves, two cameras, saved custom layouts, 50/50 split, rotation.
- Beta 4.0: background removal, smooth face tracking, cropping, LUTs, split-screen layout with smooth transitions.

### Audio

- One toggle applies automatic mic enhancement: volume normalization plus noise reduction. The two cannot be separated. The app bundle includes a `deep-filter` binary, per an HN listing.
- Mute microphone; mute system/external audio in the sidebar; per-clip volume via right-click > Set volume.
- Waveform for mic and system audio on the timeline, reflecting volume changes.
- Scrubber with audio for finding edit points.
- Background music: built-in royalty-free library with preview, plus custom upload (the guide says MP3 or MP4). Synced to the timeline.
- Click sound effects.
- Raw mic, camera and screen tracks can be extracted as separate files.
- Not available: post-recording voice-over, extra audio tracks, EQ or gain boost, mic delay offset, multitrack devices, filler-word or silence removal.
- Beta: "AI voice cleanup" (on-device). In progress: AI voiceover; Speechify is listed as a text-to-speech sub-processor in the privacy policy.

### Captions / transcript

- On-device transcription with Whisper (Base / Small / Medium), or Apple Speech Recognition on macOS 26+.
- Language is auto-detected or manually chosen; an optional prompt helps with product names.
- Requires recorded microphone audio. There are no manual captions without voice.
- Controls: show/hide, caption size, transcript editor, export transcript as a separate file with timestamps. The file format is unverified.
- Words are highlighted karaoke-style and this cannot be turned off.
- Not available in stable: position, font, colour, find/replace, timing edits, VTT import.
- Beta: "Better captions": improved style and animation.

### Timeline editing

**Cutting and trimming**
- Drag clip edges to trim; each trim shows as a bubble that can be undone.
- Split tool by holding Option or the scissors icon; C cuts at the playhead; X ripple-deletes back to the previous cut.
- Backspace removes a slice (Delete key was rejected). Minimum clip length is 100 ms. "Reset all trims and cuts" exists.

**Speed and volume**
- Per-slice speed via right-click > Set speed, including slow-down, with "Apply to all" (3.6.0).
- Users mention 1.2x, 1.4x, 1.6x, 2x, 4x, 8x and 16x; the full list is unverified. There are no custom values.
- Typing detection suggests speed-ups, with a slider and "Apply to all typing parts".

**Masks and highlights**
- Mask timeline (shortcut 4) with adjustable size and opacity.
- Only one mask or highlight can exist at a time. Masks do not track scrolling content and fade in.

**Keyboard shortcut overlay**
- Auto-detected keys, with a label size slider and a "show single key shortcuts" option that filters typing.
- A shortcuts timeline lets you disable one, all of a kind, or hide all.
- Beta: real keycap overlays.

**Navigation and workspace**
- Timeline zoom by slider, Cmd+scroll, pinch, or +/-.
- Arrows move 0.5 s, or 1 s with Shift. Loop mode exists.
- JKL playback is reported via an X post snippet and a Done hub item; I did not read the post itself.
- Preview size options; hide sidebar or timeline; Command menu (Cmd+K); shortcut cheat sheet (Cmd+/); rebindable shortcuts.
- Crop with numeric values, fixed aspect ratio and grid. Crop does not change output aspect ratio.
- Copy current frame as image (Cmd+C or context menu).
- Autosave, undo/redo, multi-select.

**Not available**
- Multiple clips or merged projects, imported media or images, text or title slides, annotations (arrows, shapes, text), transitions, freeze frame, clip reordering, export range, watermark or logo overlay.

### Backgrounds and frame styling

- Background types: Wallpaper, Gradient, Color (hex, paste from clipboard), Image upload.
- Wallpaper library: macOS Sonoma, Sequoia and Tahoe; iPadOS 17; Raycast wallpapers; 100+ from Blue Pixel Studio; glassmorphism set. Categories, favourites, random button.
- Background blur is reported by reviews; not in the current guide.
- Padding (0 removes the background), rounded corners, inset with colour, shadow with advanced controls.
- Shadow colour is fixed, shadow blur cannot reach 0, and padding is uniform on all sides (all open requests).
- Device frames for iPhone and iPad only: iPhone 11 through 17 Pro Max and iPhone Air, iPad Pro 11 and 12.9, horizontal iPad. Colour choice; frame can be disabled.
- No Mac or browser frames found in official sources.
- No transparent background (rejected; the workaround is a green background plus chroma key).
- Beta: Unsplash background search.

### Motion / animation quality

- Motion blur strength slider, with separate advanced controls for cursor movement, screen zooming and screen moving. A new blur engine shipped in 2.25.2.
- Spring-based animation engine.
- Cursor animation style: Smooth / Medium / Rapid / None.
- Screen animation: Focused (settles quickly, for reading) or Smooth (more fluid).
- Older versions had more speed presets and raw physics sliders; they were simplified.
- Preview modes: Quality (matches export), Performance (disables blur, may pixelate), Power Saving.

### Export

| Setting | Options |
|---|---|
| Format | MP4, GIF |
| Resolution | 720p, 1080p, 4K (no 1440p, no custom) |
| Frame rate | 10 to 60 fps |
| Quality | Studio, Social Media, Web, Web (Low) |
| Aspect ratio | Auto, 16:9, 9:16, 1:1, 4:3, 3:4, 4:5 |

- Compression level does not change export time; 4K takes roughly four times as long as HD (official guide).
- GIF: optimized palette mode and loop count setting. Officially discouraged over 1 minute. Users report GIF is capped at 1080p.
- Codec is unverified. One review says H.265; a hub poster says ffmpeg is used. There is no codec, bitrate or colour profile control.
- Destinations: export to file, copy to clipboard, shareable link. Quick export reuses last settings.
- Batch export of multiple selected projects shipped in 3.0. Users still request a queue.
- The editor stays usable while another window exports. Recording while exporting was rejected.
- Advanced: experimental multi-threaded export (20-40% faster, may break files), reduce export memory usage. A hardware-encoding toggle is reported by a competitor blog: unverified.
- Speed claims: "up to 4x faster" engine (2.25.2), +25% (2.25.18), beta "up to 3x faster".
- Reviewer timings vary widely, from under a minute for a 3-minute 4K clip on M2 to 30 minutes for a 10-minute video on M1 in 2023.
- Extract raw recording files: camera, microphone and screen (screen has no cursor; edits are not applied).
- Not available: ProRes, MOV, WebM, alpha, 120 fps, max-file-size target, multi-aspect export in one go (all rejected or in review).

### Sharing

- Shareable links upload to Screen Studio's cloud (Cloudflare) and open in the browser, in the form `screen.studio/share/<id>`.
- 30-minute limit per link.
- Private links with email invitations (3.4.4).
- Timestamped comments with a username (3.4.10).
- View counter that excludes the owner (3.5.1).
- Custom title; branding removal is marked Done on the hub.
- Managed from the web dashboard.
- Quick share widget after recording: Share, Save, Copy, Edit. Can be disabled.
- Not available: embed code, download button, viewer analytics, password protection, folders, 4K playback, disabling cloud for enterprise, direct YouTube or S3 upload.

### Presets / templates / projects

- Presets: create, apply, default preset for new recordings.
- Presets are shared as `.screenstudiopreset` files, which include images. Preset storage location is configurable; presets can be imported.
- "Use last project settings as default for new recordings" (Settings > Editing).
- Projects are `.screenstudio` bundles: a package directory containing recording segments, webcam, mic tracks, mouse telemetry, cursor sprites and `project.json`, unencrypted (per a community exporter README).
- Save / Save As, Open Recent, configurable default folder, drag and drop to open, rename from the top bar.
- Share projects by zipping the bundle.
- No cloud sync and no team preset sharing (rejected).

### Platform, pricing, licensing

- macOS only. Windows is officially "no near-future plans".
- Requires macOS 13.1+, 8 GB RAM, Apple Silicon (recommended) or Intel (2018+ MacBook Pro, 2020+ MacBook Air). Separate DMGs per architecture.
- Electron app (TypeScript/React). About 517 MB on disk per an HN listing. Direct download with its own auto-updater; not on the App Store or Setapp.
- Monthly: $29/month. Yearly: $9/month billed yearly ($108/year). Both include all features and shareable links.
- Education discount: 40%.
- Free download; everything works except exporting video files.
- Device limit: 3 personal Macs per third-party reports. The official agreement only says "a specified number of devices".
- Fees are non-refundable; cancellation takes effect at term end; auto-renews.
- No team plan (in progress since 2023).
- One-time licences ($89 in 2022, later $229 with one year of updates) were removed for new buyers around 2025-09-30. Legacy holders get updates through 2027-09-25 and can renew.
- Privacy: recordings and transcription are local. Usage analytics (PostHog) are opt-out. Billing via Lemon Squeezy.

### Anything else

- Speaker notes / teleprompter: a pop-out invisible to the recording, with scroll speed, opacity and font size, Cmd+Opt+. to start, and a faster speed option. Disabled when ScreenCaptureKit is off.
- AI features in stable are local only: transcription and noise removal.
- Roadmap planned: voice audio enhancement, multi-clip recordings, full text slides, enter/exit animations, videos from screenshots. Paused: annotations.
- In progress on the hub: edit by transcript, filler-word and silence remover, colour grading.
- Diagnostics sharing, user-friendly error codes, reset window positions.

## What users complain about / want (with source links)

Hub vote counts are from `hub.screen.studio` on 2026-09-29.

| # | Complaint or request | Frequency | Source |
|---|---|---|---|
| 1 | Subscription switch and price; "$29/mo is extremely expensive"; occasional users subscribe and cancel | Very frequent; the dominant complaint | https://news.ycombinator.com/item?id=47595695, https://news.ycombinator.com/item?id=46995332, https://alternativeto.net/news/2025/10/screen-studio-has-removed-their-non-subscription-licensing-options-for-new-customers/, https://prequel.sh/blog/screen-studio-alternatives (competitor, cites r/macapps) |
| 2 | Export paywall discovered only after recording; no refunds | Occasional | https://news.ycombinator.com/item?id=47072536, https://screen.studio/legal/terms-of-service |
| 3 | Cannot combine recordings or import clips | Top open request (525 + 462 votes) | https://hub.screen.studio/p/import-clips-or-append-external-video-clips, https://hub.screen.studio/p/ability-to-merge-multiple-projects |
| 4 | No text slides, titles, annotations or click descriptions | Very frequent (479, 246, 222 votes); planned 3+ years | https://hub.screen.studio/p/full-text-slides, https://hub.screen.studio/p/annotation-tools |
| 5 | No voice-over after recording; no audio import | Very frequent (337, 319 votes) | https://hub.screen.studio/p/ability-to-add-voice-over, https://hub.screen.studio/p/import-audio |
| 6 | Only one mask at a time; mask fades in, briefly exposing data | Frequent and angry (147 votes) | https://hub.screen.studio/p/multiple-mask-layers |
| 7 | No Windows or Linux | Very frequent (302 votes, rejected) | https://hub.screen.studio/p/waiting-for-windows-version |
| 8 | Camera background blur/removal | Frequent (194 votes); now in beta | https://hub.screen.studio/p/blur-camera-background |
| 9 | Filler-word and silence removal; edit by transcript | Frequent (175, 154 votes); "in progress" for two years | https://hub.screen.studio/p/filler-words-and-silence-remover, https://hub.screen.studio/p/edit-by-transcript-like-loom |
| 10 | No transparent background, ProRes or WebM | Frequent (148 votes, rejected) | https://hub.screen.studio/p/transparent-background |
| 11 | No transitions or fades | Frequent (124 votes) | https://hub.screen.studio/p/transitions |
| 12 | Export hangs (0%, 95%, last frame, >2 GB) and slow exports | Recurring; fixes shipped repeatedly | https://screen.studio/changelog, https://www.bitdoze.com/screen-studio-review/, https://www.screenkite.com/blog/fix-screen-studio-stuck-at-0-export (competitor) |
| 13 | No export queue; cannot record while exporting | Moderate (28 votes, rejected) | https://hub.screen.studio/p/bulk-bulk-export |
| 14 | Huge project files (40 GB for a 3-hour video); large 4K exports | Moderate | https://www.producthunt.com/products/screen-studio/reviews, https://hub.screen.studio/p/better-export-compression-for-4k-files |
| 15 | Auto-zoom fires on unimportant clicks, starts too late, is dizzying; no default timing control | Frequent in reviews | https://www.therundown.ai/tools/screen-studio, https://pickuma.com/for-dev/screen-studio-macos-screen-recording-review/, https://hub.screen.studio/p/custom-settings-for-default-automatic-zoom-range |
| 16 | Smoothed cursor lags behind real hover states | Low volume (18 votes) but a core-quality issue | https://hub.screen.studio/p/option-to-disable-all-screenstudios-mouse-features-or-fix-mouse |
| 17 | Physics and zoom-style controls were removed | Low | https://hub.screen.studio/p/add-back-cursor-animation-physics-customization-as-an-optional-toggle |
| 18 | Audio: enhancement and normalization coupled; quiet system audio; no gain; mic delay; low mic bitrate | Moderate, many small requests (48, 35 votes) | https://hub.screen.studio/p/separate-audio-improvement-from-volume-normalization, https://hub.screen.studio/p/add-mic-delay-option |
| 19 | Audio bugs (metallic, robotic, distortion, desync) | Recurring in 2025-2026 changelog | https://screen.studio/changelog |
| 20 | Captions: no position or font control; karaoke highlight fixed; words lost after cuts; weak Chinese/Arabic | Moderate | https://hub.screen.studio/p/more-transcript-display-options-please, https://hub.screen.studio/p/transcript-timings-adjustments |
| 21 | Shareable links: 30-minute cap, no embed, download, analytics or password | Moderate (50, 36 votes) | https://hub.screen.studio/p/embed-link-embed-code, https://hub.screen.studio/p/views-analytics |
| 22 | Cloud cannot be disabled, blocking enterprise approval | Low-moderate (23 votes) | https://hub.screen.studio/p/ability-to-turn-off-cloud-sharing-so-designers-at-security |
| 23 | No team plan | Moderate; teams of 20 waiting | https://hub.screen.studio/p/teams-subscriptions-architecture |
| 24 | Camera cannot be freely moved or resized over time; no camera zoom or custom split | Moderate (61, 39, 41 votes) | https://hub.screen.studio/p/ability-to-make-camera-biggersmaller-in-post-edit-and-move |
| 25 | No watermark, still images or freeze frame | Moderate (88, 54, 58 votes) | https://hub.screen.studio/p/watermark-add-logo-png-to-all-video-or-export |
| 26 | Export options: no 1440p, no range export, GIF capped at 1080p | Moderate (54, 12 votes) | https://hub.screen.studio/p/allow-exporting-by-sections-or-range |
| 27 | Window mode records overlapping windows and does not follow the window | Low-moderate | https://hub.screen.studio/p/follow-window-movement-and-ignore-other-windows |
| 28 | iOS recordings: no tap indicators, no auto zoom | Low-moderate | https://hub.screen.studio/p/show-taps-with-highlights-on-ios-and-ipados-recordings |
| 29 | Auto-updater incident: a 250 MB update re-downloaded every 5 minutes for over a month (2+ PB); no way to disable auto-update | One-off but high-profile | https://pietrasiak.com/one-line-of-code-that-did-cost-dollar8000, https://news.ycombinator.com/item?id=43829006 |
| 30 | Electron: app size, resource use, crashes | Occasional | https://news.ycombinator.com/item?id=43816419 |
| 31 | Timeline UX: hard on long recordings, coarse speed steps, typing speed-up makes too many cuts | Low-moderate | https://hub.screen.studio/p/i-desperately-need-more-granularity-on-playback-speed, https://hub.screen.studio/p/too-many-cuts-in-typing-speed-up |
| 32 | Discoverability: "remove all zooms" hidden behind a right-click | Low | https://hub.screen.studio/p/remove-all-zooms-button |
| 33 | No light theme; not on Setapp; no pay-as-you-go | Low (5, 44, 4 votes; all rejected) | https://hub.screen.studio/p/light-theme |

**Counterpoint:** some users tried Cap and ScreenSage and returned, saying Screen Studio "is reliable and produces the best results" (https://news.ycombinator.com/item?id=47647872). Product Hunt shows 4.9/5 from 187 reviews.

**Unreliable third-party claims to ignore:** MOV export, iOS tap indicators, "no captions or teleprompter", "no device frames" and "no share links" all contradict official sources.

## Sources

**Official**
- https://screen.studio (raw HTML and FAQ bundle)
- https://screen.studio/changelog
- https://screen.studio/roadmap
- https://screen.studio/beta
- https://screen.studio/download
- https://screen.studio/guide and about 60 sub-pages, including recording, zoom, cursor, camera, captions, export, presets, shareable links and licence pages
- https://screen.studio/create/loom-vs-screen-studio, /create/screen-recorder-with-audio, /create/screen-recorder-with-keyboard-shortcuts
- https://screen.studio/legal/terms-of-service
- https://screen.studio/docs/legal/terms-of-service/master-subscription-agreement.pdf
- https://screen.studio/legal/privacy-and-cookie-policy
- https://screen.studio/affiliate
- https://screen.studio/sitemap.xml
- https://hub.screen.studio/ (public API: all 296 requests plus comment threads for about 28 of them)
- https://pietrasiak.com/one-line-of-code-that-did-cost-dollar8000
- https://raw.githubusercontent.com/raycast/extensions/main/extensions/screen-studio/package.json

**Community and independent**
- https://news.ycombinator.com/item?id=47595695
- https://news.ycombinator.com/item?id=47645554
- https://news.ycombinator.com/item?id=43816419
- https://news.ycombinator.com/item?id=43829006
- https://news.ycombinator.com/item?id=34045110
- HN Algolia comment and story search for "Screen Studio" (2024-2026)
- https://www.producthunt.com/products/screen-studio/reviews
- https://alternativeto.net/news/2025/10/screen-studio-has-removed-their-non-subscription-licensing-options-for-new-customers/
- https://alternativeto.net/news/2024/12/screen-studio-3-0-launched-with-shareable-links-dynamic-layouts-command-menu-and-more
- https://alternativeto.net/software/screen-story/about/
- https://pricetimeline.com/news/173
- https://github.com/vignesh-sabhahit/screenstudio-export
- https://buildwith.app/apps/screenstudio
- https://www.starterstory.com/screen-studio-breakdown
- https://www.trustpilot.com/review/screen.studio (no reviews)

**Reviews**
- https://daveswift.com/screen-studio/
- https://www.bitdoze.com/screen-studio-review/
- https://www.dailytut.com/apple/screen-studio-review-mac.html
- https://pickuma.com/for-dev/screen-studio-macos-screen-recording-review/
- https://www.therundown.ai/tools/screen-studio
- https://affmaven.com/screen-studio-review/
- https://filmora.wondershare.com/video-editor-review/screen-studio-review.html
- https://www.mobileappdaily.com/product-review/screen-studio
- https://denshub.com/en/screen-studio-app-review/
- https://dockshare.io/apps/screen-studio
- https://checkthat.ai/brands/screen-studio
- https://mavtools.com/tools/screen-studio-create-edit-screen-recordings/
- https://ahoi.dev/screen-studio-3-0/
- https://www.datastudios.org/post/screen-studio-auto-zoom-mechanism-mac-only-limits-and-pricing-explained
- https://stackedreview.com/screen-studio-pricing/
- https://guideclarity.com/alternatives/screen-studio

**Competitor-authored (biased)**
- https://matte.app/blog/screen-studio-review
- https://www.screenkite.com/blog/screen-studio-subscription-free-alternative
- https://www.screenkite.com/blog/fix-screen-studio-stuck-at-0-export
- https://www.screenkite.com/blog/native-vs-electron-screen-recording
- https://cursorclip.com/blog/cursorclip-vs-screenstudio/
- https://cursorclip.com/blog/screen-studio-alternatives/
- https://cursorclip.com/blog/screen-studio-discount-code/
- https://screencharm.com/vs/screen-studio
- https://supademo.com/blog/screen-studio-alternatives
- https://www.tella.com/alternatives/screen-studio
- https://borumi.com/blog/comparison/tella-vs-screen-studio/
- https://borumi.com/blog/article/support/screen-studio/how-to-fix-screen-studio-editor-lag/
- https://borumi.com/blog/article/support/screen-studio/how-to-improve-slow-video-exports/
- https://tight.studio/resources/how-to-record-clip-by-clip-in-screen-studio/
- https://focusee.imobie.com/reviews/screen-studio-review.htm
- https://www.smoothcapture.app/blog/screen-studio-alternative
- https://zumie.io/blog/top-8-screen-studio-alternatives
- https://prequel.sh/blog/screen-studio-alternatives

**Attempted but not readable**
- reddit.com (blocked)
- x.com posts (403 or redirect)
- https://efficient.app/apps/screen-studio (429)
- https://cutsio.com/blog/screenstudio-review-2026 (403)
- scribehow.com pages (401)
- https://www.raycast.com/screen-studio/screen-studio/commands (command list not rendered)
- https://screen.studio/llms.txt (fetched, content not reproduced by the fetch tool)
- https://screen.studio/pricing, /help, /use-case (404)
