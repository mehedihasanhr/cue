# 7. Working notes

How to work in this codebase. Read this before changing anything.

## Where things are

| Path | What it is |
|---|---|
| `Packages/RecordKit` | Recording: capture, the one clock, writers, telemetry, the `.klikrec` package and its manifest |
| `Packages/TimelineKit` | The edit as one `Codable` value (`Timeline`), commands, analysis (pointer path, zoom suggestions, captions) |
| `Packages/RenderKit` | `SceneBuilder` (pure) makes a `SceneDescriptor`; `SceneRenderer` draws it. Preview and export use the same two |
| `Packages/BackgroundKit` | Wallpapers, gradients, colours |
| `Packages/AddOnKit` | What Klik and an add-on say to each other |
| `KlikStudio/App` | The recorder: bar, target picker, settings, windows |
| `KlikStudio/Editor` | The editor: model, preview, timeline, inspector panels, export |
| `Tools/studio-lab` | `studiolab`: measures recordings and drives the app through Accessibility |
| `docs/studio` | The plan. `03-feature-list.md` and `05-roadmap.md` say what is wanted; `04-architecture.md` says how it fits |

The Xcode project uses synchronised folders. A new file in `KlikStudio/` is part of the app as soon as it exists. Do not edit `project.pbxproj`.

## Rules of the design

1. **One clock.** Every time written during a recording comes from `RecordingClock`. Nothing keeps a second idea of "now" or of how long a pause was.
2. **One renderer.** Anything drawn in the video is a layer in `SceneDescriptor`, built by `SceneBuilder`, drawn by `SceneRenderer`. Never draw something in the preview that export does not also draw.
3. **The edit is a value.** Every change to `Timeline` is a `TimelineCommand` applied through `EditorModel.apply`. That is what makes it undoable. Style changes use `Commands.Restyle(name) { … }` or the inspector's `StyleBinding`.
4. **Old projects open.** A new stored field gets a default in a hand-written `init(from:)` that decodes field by field with `decodeIfPresent`. Add a test that decodes JSON without the field.
5. **Three coordinate spaces.** The recording (blurs), the cropped picture (zoom centres, pointer), the finished frame (annotations, captions, camera). Say which one a number is in.
6. **Logic lives in the packages, views in the app.** If it can be tested without a window, it goes in a package with tests.

## Style

- Match the code around you: naming, spacing, how much is commented.
- Comments explain why, in plain sentences. Most say what went wrong before or what the rule is for. No banner comments, no restating the code.
- Words shown to the user are plain and short: "Hide while it is still", not "Enable idle cursor auto-hide".
- Inspector panels are built from `inspectorSection`, `InspectorField`, `InspectorPicker`, `InspectorSlider`, `InspectorRow`, `SectionButton` in `KlikStudio/Editor/Inspector/InspectorControls.swift`. Use them; do not restyle controls one at a time.
- Anything the editor can do gets a menu item in `KlikStudio/Editor/EditorCommands.swift`. Keyboard shortcuts live there, not on buttons.
- A disabled control has its reason written beside it.
- Both appearances. Check light and dark: white on a light lane and dark on a dark one are the usual mistakes.

## Building and testing

```
swift test --package-path Packages/TimelineKit
swift test --package-path Packages/RenderKit
swift test --package-path Packages/RecordKit
swift test --package-path Packages/BackgroundKit
xcodebuild -project Klik.xcodeproj -scheme Klik -configuration Debug build
```

Tests use Swift Testing (`@Test`, `#expect`). A filter runs one suite: `swift test --package-path Packages/TimelineKit --filter CaptionCommandTests`.

**Done means:** tests written and passing, every package's tests passing, the app building with no warnings and no errors, and the roadmap and quality log updated.

## Testing the running app

The Mac is in use by a person while tests run. So:

- Never click or type at screen coordinates. A click lands on whatever is there.
- Launch the app without bringing it forward: `open -g -a "<path>/Klik.app" --env KLIK_STUDIO_QUIET=1 "<recording>.klikrec"`. Studio is part of Klik, so this is Klik's own Debug build.
- Drive it by process: `studiolab menus "pid:<pid>"`, `studiolab press "pid:<pid>" "<menu item>"`, `studiolab shot "pid:<pid>" out.png`. The name "Klik" can match the installed copy too, so a pid is safer.
- Controls inside a window can only be reached while that window is on the current Space. Menu items can always be reached, which is one more reason every action has one.
- `studiolab pointer` and `studiolab stream` cover the screen and move the pointer for about 25 seconds. Do not run them without being asked.
- Work on a copy of a recording, not on the ones in `~/Movies/Klik Studio`.

## Process rules

- Stop what you start. Kill only the process you started, by its id. Never `killall` or `pkill` by name.
- Do not commit, push, stash, reset or switch branches unless asked.
- Shell commands that chain `rm` with other commands may be refused. Run simple commands one at a time.
