# 6. Quality log

Every bug found, how it was measured, and what fixed it. Newest work first.

Measurements come from `Tools/studio-lab`, which records a scripted pointer over a blank stage with the real pointer burnt into the picture, then compares what was written down with what is in the frames. Mac used: MacBook Pro, built-in display at 1512 × 982 points, 120 Hz.

## Finding sensitive text (2026-09-29)

Measured on synthetic H.264 footage at 1280 × 720 (`SensitiveScannerTests`), against where and when each line was drawn:

| Case | Found | False alarms | Timing and place |
|---|---|---|---|
| Page of seven kinds at 18–20 px, with eight decoys (versions, dates, a price, an order number, a hash) | 7 of 7 | 0 | Every mask starts at or before the first frame and ends at or after the last, by no more than 3 frames; covers the text on its first, middle and last frame |
| The same seven at 14 px, each on a white box over a page of ordinary words | 7 of 7 | 0 | Covers the text from its first frame |
| An email scrolling 4 px a frame | 1 of 1 | 0 | Covers the text on every frame; path of 2 keys |
| A phone number scrolled 48 px every 7 frames, off the sampling rhythm | 1 of 1 | 0 | Covers the text on every frame it is in the picture (followed frame by frame, 41 keys) |

Found along the way: text recognition reads a password field's bullets as full stops (`•......•`, `........`), and does not read ten 20 px bullets on their own as text at all. Runs of full stops now count when they are the whole line or follow "Password"; a field of bullets with no label beside it and too small to be read is not found. Edges were first found with the exporter's frame reader, which answers a step back of less than a frame with the frame it holds; edge searches now seek exactly.

## Pointer and picture sync (2026-09-29)

The reported symptom: "the click position and the mouse position do not match".

### Measured before and after

| Measurement | Before | After | How it is read |
|---|---|---|---|
| Picture answers a pointer jump after a still screen | 67.7 ms late | 2.2 ms | First frame showing the pointer in its new place, against the first sample saying so |
| Pointer against picture while moving | 9.5 ms ahead (8.5 pt at 900 pt/s) | 0.0 ms | Best-fit time shift over a constant-speed sweep |
| Pointer after a 2-second pause | 1,952 ms late | 1.7 ms | Same, for jumps made after the pause |
| Click drawn away from the pointer after a pause | 280 pt | 0.0 pt | Drawn pointer against its own click ring |
| Frames in which the pointer could be found | 891 of 956 | 1,001 of 1,001 | Frames read from the file |
| End of the recording | 0.78 s missing | Complete | File length against the telemetry |

Results by target after the fixes (31 checks each):

| Target | Checks passed | Clock offset | After a pause |
|---|---|---|---|
| Display | 31 of 31 | 0.0 ms | +1.7 ms |
| Area | 31 of 31 | −4.0 ms | −2.1 ms |
| Window | 31 of 31 | +5.0 ms | +0.9 ms |

The remaining ±5 ms is a third of a frame. It comes from capturing a 120 Hz display at 60 frames a second and varies from take to take.

### Causes and fixes

| # | Cause | Fix | Test |
|---|---|---|---|
| 1 | **Pauses were taken out of the video but not out of the pointer.** Each writer kept its own total of paused time; telemetry kept none | `RecordingClock` owns every pause. Writers and telemetry all ask it | `TimingTests`: 5 tests on holds |
| 2 | **The first frame after a still screen was dropped.** The stillness was filled with repeated frames in one burst, the encoder stopped accepting, and the real frame behind the burst was lost | Idle frames from ScreenCaptureKit keep the file in step one frame at a time. Filling stops when the encoder is busy, and the real frame waits up to 50 ms for it | Measured with `studiolab pointer` |
| 3 | **The recording ended early** for the same reason: the tail was filled in a burst | The tail waits for the encoder | Measured |
| 4 | **The clock started when the first frame arrived**, not at the frame's timestamp. A few milliseconds, different every take | `clock.start(at:)` takes the frame's own timestamp | Measured with `studiolab stream` |
| 5 | **Clicks were stamped when the app was told about them**, with wherever the pointer had got to by then | The event's own timestamp and location are used | `TimingTests`: 2 tests |
| 6 | **The pointer ran one display refresh ahead of the picture.** The screen shows the pointer a refresh after the system knows where it is | Pointer times are moved by one refresh of the recorded display (`PointerLatency`), and the amount is written in the manifest | `PointerLatencyTests`: 2 tests |
| 7 | **The pointer's path and its clicks were two accounts of one thing.** The path is sampled on a timer and is always slightly stale | Every press and release is added to the path as a sample | `CursorClickPinningTests`: 7 tests |
| 8 | **Frames could arrive in the wrong order across a pause** | A frame stamped before the last one written is dropped | Covered by the pause measurement |

Recordings made before these fixes keep their old timing. The manifest's `pointerLatency` field is absent on them.

## Pointer drawing (2026-09-29)

| # | Bug | Effect | Fix | Test |
|---|---|---|---|---|
| 9 | Every drawn pointer was placed by its top-left corner | The I-beam, crosshair and resize pointers were drawn half a pointer right and down. The arrow was about 3 px out | Each shape is placed by its own hotspot | `PointerPlacementTests`: 6 tests, which fail against the old renderer |
| 10 | Motion blur moved the pointer | A fast pointer was shifted by the length of its smear, up to 40% of its size | The pointer is put in place first and smeared afterwards | Same suite, four directions |

## Preview (2026-09-29)

| # | Bug | Effect | Fix | Test |
|---|---|---|---|---|
| 11 | Cached frames were filed in 20 ms buckets; a frame at 60 fps lasts 16.7 ms | Stepping through a click could show the pointer over the frame before or after the one it belonged to. Export was never affected | Frames are filed under the recording's own frame index, read once from the file without decoding | `FrameSourceTests`: 7 tests |
| 12 | "Next frame" moved 1/30 s whatever was recorded | At 60 fps every press skipped a frame | Steps by the recording's frame rate, landing on a frame | — |

## Editing (2026-09-29)

| # | Bug | Effect | Fix | Test |
|---|---|---|---|---|
| 13 | Blur outlines ignored the crop | On a cropped project the outline was in one place and the blur in another | `PictureMapping` maps footage through the crop | `FootageMappingTests`: 5 tests |
| 14 | Auto zoom ignored the crop | Suggested zooms were aimed beside their clicks; clicks that had been cropped away still made zooms | `ZoomSuggester` takes the crop | `CropAndZoomTests`: 4 tests |
| 15 | Changing the crop left zooms aimed at the same fraction of a different picture | Crop the left half away and every zoom pointed somewhere else | `SetCrop` re-aims each zoom at what it was already aimed at | `CropAndZoomTests`: 5 tests |
| 16 | Pasted footage lost annotation rotation, opacity, animation and hidden state | A copy was a different annotation | Every field is carried | `CopiesKeepEverythingTests`, which compare every stored field by reflection |
| 17 | A switched-off zoom came back on when copied | The copy undid an edit | `isEnabled` and `isEdited` travel with the zoom | Same suite |
| 18 | Trimming the start of an imported sound slid the whole sound | Music or a voice-over arrived late by as much as was trimmed | A head trim moves the in-point and keeps the far edge | `SoundHeadTrimTests`: 7 tests |
| 19 | A sound's front edge could be dragged past the start of its file | The sound slid instead of stopping | The edge stops where the file starts | Same suite |
| 20 | Zooms, pointer stretches and captions could go out of time order after a drag | "Merge with next" merged with the wrong zoom | Those lanes are re-sorted after a move. Annotations are not, because their order is the stacking order | `LaneOrderTests`: 5 tests |

## Recorder and app (2026-09-29)

| # | Bug | Effect | Fix | Test |
|---|---|---|---|---|
| 21 | The target overlay was marked a floating panel, which reset its window level | The window picker could not appear over a full-screen app | The level is left as set | Checked against the window server's list |
| 22 | The recorder bar changed width about its left edge | The bar sat off-centre for the whole of every take, and drifted further left each time | The bar keeps an anchor: the middle of its bottom edge | Checked on screen |
| 23 | Every recording opened another editor window | Windows piled up | One editor; opening another recording replaces it | Checked on screen |
| 24 | "Automatic" encoder asked whether the Mac can *decode* HEVC | A Mac that can play HEVC but not encode it in hardware would encode on the processor | Asks for a hardware encoder | — |
| 25 | Studio told Klik it could not export GIFs or make captions | Out-of-date capability list | Both reported as supported | — |
| 26 | A doc comment and `@discardableResult` had come loose from `addBlur` and attached to `addSound` | Two compiler warnings | Put back | Build |
| 27 | 12 compiler warnings in the app, 4 in the packages | Noise that hides real ones | All fixed; the build is clean | Build |
| 28 | A playback test waited a fixed 0.7 s for the audio clock | Failed whenever a Bluetooth headset was asleep | Waits until the clock is moving | 15 runs, no failures |

## Menus, panel and timeline (2026-09-29)

| # | Bug | Effect | Fix | Test |
|---|---|---|---|---|
| 29 | The menu bar acted on the editor only once its window had become main | An editor opened behind another window had every command disabled, with the editor plainly open | The editor is the menu bar's editor from the moment it is created | Checked through Accessibility |
| 30 | "Delete" and "Select All" appeared twice in Edit; Save and the eight tools were missing | Shortcuts advertised on the tool rail did nothing unless the rail had the keyboard | One set of menus, with the shortcuts in the menu bar | Menu listing |
| 31 | Opening a recording marked it as edited | Auto zoom returned after the user had removed every zoom and saved | Zooms suggested on open are a baseline, not an edit | Checked in the app |
| 32 | Pointer shapes made of two pieces showed the seam between them | An outline ran through the middle of the hand and the resize arrows | Pieces are joined into one outline before drawing | `PointerStyleTests` |
| 33 | Hand pointers were drawn as arrows | The pointer shape in the video did not match what was on screen | Open hand, closed hand and pointing hand are drawn as hands | `PointerStyleTests` |
| 34 | A condition in the pointer panel ended in `&& false` | The section could never be switched off when it should be | Removed | Build |
| 35 | With Pointer, Webcam, Captions or Audio open, selecting something on the timeline changed nothing in the panel | A zoom or a caption could be selected but its settings could not be reached | The panel answers whichever was chosen last: a tool or a thing on the timeline | Checked in the app |
| 36 | In light mode a selected chip had a dark ring and white end grips | The grips vanished into the lane and the ring looked like two stray lines | Grips are drawn in the ring's ink | Checked in the app |
| 38 | The click mark is white by default and had no edge | A click on a document, a web page or a spreadsheet could not be seen at all | Every mark has a soft edge of the opposite tone under it, made from its own shape | `PointerStyleTests`: white on white, black on black, and gone when the mark is |
| 39 | Adding a caption with the playhead inside another cut that caption short | The line before was reduced to a sliver | The new line goes in the first free stretch after it, and the playhead moves there | `CaptionPlacementTests`: 12 tests |
| 40 | A caption chip narrower than its words showed them cut at both ends | "mpty captio" | Words are shortened with an ellipsis; the name goes first when room runs out; nothing is shown when nothing legible fits | Checked in the app |
| 41 | The Webcam panel gave its reason last | A column of controls that appeared to do nothing, explained at the foot | The reason is first | Checked in the app |
| 42 | One switch among the editor's checkboxes | A sound source looked like a different kind of setting | A tick, like the rest | Checked in the app |
| 43 | Click rings ignored stretches that hide the pointer | A ring appeared out of nowhere where the pointer had been hidden, though the code's own comment said it would not | Rings fade with the pointer and are gone while it is hidden | `HiddenPointerClickTests` |
| 44 | An added sound's waveform was drawn in the lane's coordinates on a canvas the width of the chip | Any sound further along the timeline than it was long showed a plain chip, so music could not be lined up by eye | The waveform is given the lane's width and slid back to the chip | Checked in the app |
| 45 | The clip's speed menu drew its title in the window's label colour whatever it was told | Dark grey on a dark backdrop once the clip lane showed pictures | The label's backdrop declares itself dark, so the system control draws light | Checked in the app |
| 46 | Picture annotations existed in the model and the renderer but nothing in the app could add one, and the renderer read the stored path as it was | No way to put a logo or a screenshot on the video; a picture kept inside the project would not have been found | "Picture…" and "Logo…" in the annotation menu; pictures are copied into the project as PNG, named relative to it, and resolved when drawn | `PictureAnnotationTests`, `PicturePlacementTests` |
| 47 | Pictures were stretched to their box | Dragging a corner squashed a logo | Drawn to fit inside the box, keeping their shape | `PictureAnnotationTests` |
| 37 | The test driver matched a control by part of its name, and could press a title in the menu bar | "Pointer" pressed "Hide Pointer over Selection"; "Captions" could have opened a menu on screen | Exact names only unless asked; menu-bar titles are never pressed | — |

## Found by review and fixed (2026-09-29)

A read-only review of editing, playback and export, each finding confirmed by a test or by tracing the code with real inputs.

| # | Bug | Effect | Fix | Test |
|---|---|---|---|---|
| 48 | The export marked the sound finished only after the last frame | An edit whose sound ends before its picture (music under the first half, a short voiceover) hung the export for ever | The sound is marked finished the moment it runs dry; the tail waits for the encoder instead of giving up | `ExportSoundLengthTests` |
| 49 | GIF frame delays were written as 0.03 s for a thirtieth of a second | GIFs ran a tenth fast: 30 s of edit played in 27 s | Rounding spread across frames (3, 4, 3 hundredths…) | `GIFTimingTests` |
| 50 | A speed change stretched regions inside the stretch, then moved everything after it, including what it had just stretched | Slowing 10–20 s to half speed sent a zoom at 16 s to 32 s instead of 22 s | One time mapping for both ends of every region | `RetimeTests` |
| 51 | A speed change with the sound detached made runs longer at the old speed | Ten seconds of sound under twenty seconds of picture; out of sync from there on | Runs are cut at the stretch and the inside part takes the new speed | `RetimeTests` |
| 52 | Deleting a stretch under a detached run shortened the run | The sound after the cut played the deleted seconds and fell behind the picture | Runs are cut where the picture is cut | `DetachedCutTests` |
| 53 | A region that began inside a cut kept its start | It started late by however much of it was cut; an added sound played its cut beginning | Moved to where the cut is; sounds advance their in-point | `CutRegionTests` |
| 54 | Trimming a clip's head moved regions on the trimmed-away footage onto the clip before | A zoom landed on the wrong clip | A head trim is a ripple delete of what was trimmed | `HeadTrimRegionTests` |
| 55 | A clip trim applied an edit on every mouse movement, each to the last one's result | Dragging past a zoom and back deleted it; dragging back and forth reshaped zooms | Every step is one trim of the timeline as the drag found it | `FromSnapshotTests` |
| 56 | A region's start handle dragged past 0 kept its length | The end moved too | The start stops at 0 and the end stays | `HeadDragTests` |
| 57 | A sound rebuild during playback came back in where Play had been pressed | Any edit while playing sent the playhead back to that moment | Comes back in where the old player had got to | Traced |
| 58 | A preview-quality frame decoded just before a scrub let go was cached as the exact one | The picture came to rest on a soft frame | Decodes from an abandoned quality are dropped | Traced |
| 59 | The detached sound lane drew its waveform on a canvas the width of the piece | Pieces further along than they were long had no waveform | Same fix as #44 | Checked in the app |
| 60 | Saved looks listed pointer and camera settings field by field, and new ones were missing | Click sounds and gliding did not travel with a look | Added; a reflection test now fails if a setting is left out | `LookFidelityTests` |
| 61 | ⌥ with a letter counted as a shortcut | On most European keyboards that is how @ and brackets are typed, so they were kept | Only ⌘ or ⌃ (or a named key) makes a shortcut | `KeyCaptureTests` |
| 63 | The keys overlay moved clear of captions but not of the camera bubble | Keys parked in the bubble's corner were drawn over the person's face | The bubble is one more thing the keys move clear of | `KeysClearOfBubbleTests` |
| 62 | The chosen tab's words were white on a pale wash in light mode | "Gradient" could barely be read | The accent colour in light mode, white in dark | Checked in the app |
| 64 | ⌘S deleted background pictures the edit no longer used, but the undo stack survives a save | Undo after a save could go back to a background whose file was gone, so the frame showed no background | Unused backgrounds and pictures are deleted only when the window closes with everything saved | Traced; built |
| 65 | Pictures removed from a project stayed in its `Images` folder for ever | Projects grew with every logo tried and discarded | Pruned with the backgrounds as the window closes, keeping whatever the saved edit shows | Traced; built |
| 66 | A fading click ring was filled with a wash of its own colour | The hole was cut with the ring's faded colour, and source-out keeps one minus that alpha: a quarter-strength disc inside the ring at half faded | The hole is cut with an opaque disc | Found by the pointer work; all RenderKit tests pass |
| 67 | A copied pointer stretch was described only as hidden, held or calmed | A spotlight or magnifier stretch on the clipboard said "calmed" | Every override it carries is named | Traced |
| 68 | Exporting a selection rebuilt each added sound field by field and dropped its fades | An excerpt's music started and stopped abruptly where the full export faded | The whole sound is copied | `VoiceFinishTests` (voice work) |
| 69 | **Every exported frame was one frame ahead of the preview and the pointer** | A decoded sample has no duration, so the export's frame reader took "this frame's end" to be its start and walked on to the next frame | The reader looks one frame ahead to know when each frame ends | `ExportFrameReaderTests` (fails on the old code) |
| 70 | A square frame with a shadow exported with the whole background black | With no rounding, the shadow's shape was a plain block of colour, and Core Image folded "block, blurred, cropped" into a colour with no edges | The shape always has a pixel of rounding, invisible under the blur | `FrameShadowTests` (fails on the old code) |
| 71 | The frame's and the camera bubble's shadows were solid bands with a hard outer edge | The shape was clamped to its extent before blurring, which repeats its solid sides out to infinity | Blurred as it is; the magnifier's shadow the same | `FrameShadowTests`, `WebcamLookRenderTests` |
| 72 | The last word of some caption lines was never drawn | The plate's size was rounded to the nearest pixel; rounded down, the words wrapped to a line below the plate | Rounded up | `CaptionStyleRenderTests.theLastWordOfALineIsDrawn` |
| 73 | Auto-Zoom placed its zooms at recording times as if they were edit times | After any cut, speed change, freeze frame or title, suggested zooms landed on the wrong moment | Each goes where its moment now is in the edit; one whose moment was cut goes | `AutoZoomPlacementTests` |
| 74 | Cuts and speed changes within 0.1 s of an existing cut moved regions by the requested amount, not by what was actually cut | A zoom 20 s later landed 15 s early; the second of two close filler words was never removed | The edge moves to the existing cut, and regions move by what went | `ClipDriftTests` |
| 75 | A speed change over clips already at different speeds used one factor for all of them | Zooms misplaced; detached sound 2.5 s out of sync with the picture | Retimed clip by clip | `ClipDriftTests` |
| 76 | Trimming a clip's tail left the regions on the cut-off footage in place | A zoom ended up over the next clip | Removed with the footage, as for the head | `RegionDriftTests` |
| 77 | Speed changes and caption edge drags stretched a line's word timings evenly | Remove Filler Words cut the wrong audio; the word highlight drifted | Words are moved one by one, and those left outside are dropped | `RegionDriftTests`, `ClipDriftTests` |
| 78 | Merging a hand-corrected caption with the next turned its guessed word timings into "recorded" ones | Filler removal then cut where the guess said | Recorded timings are kept only when both lines have them | `ReviewFixTests` |
| 79 | An excerpt export restarted sound fades at its own edges | Music taken from mid-fade started from silence in the excerpt | A cut-out piece carries on its fades from where they were | `ReviewFixTests` |
| 80 | Shortcuts drawn on screen stayed at full-edit times in an excerpt | Every keystroke showed late by the excerpt's start | Moved onto the excerpt's clock | `CameraLayoutTests` (camera work) |
| 81 | Click sounds played for clicks outside the crop | A click out of nowhere, where no ring or pointer is drawn | Only clicks inside the crop are heard, in preview and export | `ReviewFixTests` |
| 82 | Pictures pasted from another recording were invisible | Their files are inside the project they were added to | Refused with a message, or left out of pasted footage | `ReviewFixTests` |
| 83 | Discarding a take deleted its package while the writers were still cancelling | Left-over files in a discarded take | Discard waits for the writers | `RecorderBarTests` (recorder work) |
| 84 | Adding any setting to the camera bubble would have reset every old project's bubble | It used the synthesised decoder | Decoded field by field | `WebcamSettingsTests` |
| 85 | With "Zoom the whole picture" off, the frame's corners went square for the whole of a zoom | — | Kept round | Export work test |
| 86 | Settings the encoder refused crashed the export with an Objective-C exception | The writer input was built without checking | Checked first, and the export fails with a message | Export work |
| 87 | A render comparison test failed about 1 run in 15 under load | Core Image rounds a faded overlay one step differently depending on how it compiles the program; invisible | The test allows that one step; a wrong cached picture is still caught | `RenderFidelityTests.coreImagesOwnRoundingIsNotADifferentPicture` |

## Canvas, labels and export polish (2026-09-29)

| # | What was wrong | What the user saw | Fix | Proof |
|---|---|---|---|---|
| 88 | Resize handles were small white squares with a hard shadow, a different size in every overlay | The user: "showing small squares … not look good" | Round corner knobs, slim side pills (only on sides long enough), a turn knob with an arrow, a thin two-tone outline; Photos-style brackets on the crop | Checked in the app |
| 89 | A text label's frame was the box it was drawn in, not the words | Handles out in empty picture; resizing the frame changed nothing visible | The box is the words: typing grows it, a side sets where it wraps, a corner scales the type, the height is the lines | `AnnotationFitTests`, `LabelFittingRuleTests`, checked in the app |
| 90 | Boxes could only be lined up by eye | Labels a few points off centre | Edges and centres snap to the frame and to other boxes, with guide lines; ⌘ drags freely | `CanvasSnappingTests` |
| 91 | An export's sound track ended where its sound did, up to seconds before the picture | Two tracks of different lengths in an editor; a gap at the end | Silence written after the sound runs out, kept a second ahead of the picture, closed at the edit's end | `ExportSoundLengthTests`, `studiolab everything` |
| 92 | A stalled movie reader hung a whole test run | Test runs that never finished when several ran at once | Movie-reading suites run one test at a time with a time limit | 527 RenderKit tests in 17 s |

`studiolab everything` exports one edit with every feature in it: a title, a freeze frame, three kinds of transition, eight kinds of annotation, four kinds of mask, eleven captions, a camera layout, a dot pointer with a spotlight, click sounds, a browser frame on a custom gradient, keep-zoomed-in and zoom motion blur. Picture and sound both end within 6.7 ms of the edit, and every click sound is within 0.1 ms of its click.

## Export checked on a real recording (2026-09-29)

`studiolab export` on the 33-second test recording with click sounds on: picture within 6.7 ms of the edit's length, all five click sounds heard within 0.1 ms of their clicks.

## Pacing checked on real recordings (2026-09-29)

`studiolab pace` runs the same analysis as Edit › Speed Up Waiting… and prints what it read. Reading the picture takes 3.1 s for the 65-second recording and 1.5 s for the 33-second one.

| Recording | Busy | Offered |
|---|---|---|
| 65 s, pointer and screen busy throughout | 30 pointer stretches, 13 screen stretches, no typing, no captions | Nothing. The longest quiet gap is 1.8 s, under the 2.5 s floor |
| 33 s, spoken, the pointer still until 23 s | Captions to 13 s, clicks from 23 s | 13.4–22.7 s at 4×, saving 7.0 s. It keeps 0.4 s at full speed on each side |

The sheet opened in the running app (a 460 × 336 window). It could not be photographed because the Mac was on another Space at the time. The layout still needs checking by eye, and so do the annotation kinds merged the same day.

## Exports made to a size, measured (2026-09-29)

`ExportTargetTests` encodes 640 × 360 noise at 30 fps — a picture that spends every bit it is given.

| Export | Asked | Written |
|---|---|---|
| 3 s, Better (H.264) | 1.0 Mb/s | 457 KB |
| 3 s, Smaller File (HEVC) | 0.25 Mb/s floor | 213 KB |
| 4 s MP4, Best, 400 KB limit | 729 kb/s | 372 KB, 739 kb/s in the track |
| 4 s MOV, Best, 400 KB limit | 729 kb/s | 375 KB, 745 kb/s in the track |

## Window recordings with a black band (2026-09-30)

| Problem | Cause and fix |
|---|---|
| A full-screen Chrome recorded with 140 points of black down the right for the whole take | The picked window was only the page (1512 × 861); the capture also takes the tab strip and toolbar stacked above it, so the picture was 1512 × 949 and was shrunk into a file sized for the page. Window recordings are now measured from a real frame before the countdown (`WindowPicture`, about 130 ms) and the file is sized to the picture. Test: `WindowPictureTests`. A live check found a Safari window reporting 723 × 353 whose picture was 1362 × 830 |
| A window resized after recording starts still gets bars — **fixed** | The file's size is fixed once it starts, so ScreenCaptureKit scales the resized window to fit and leaves the rest black. Each frame's attachments say where the picture landed; the recorder now writes that down whenever it moves by more than half a point (`PictureTracker`, `telemetry/picture.jsonl`, window takes only, named in the manifest as `telemetry.picture`, absent from older packages). The editor reads it (`PictureTrack`) and folds the picture's rectangle into the crop the renderer already takes (`SceneBuilder.pictureCrop(at:)`), so the preview, stills and export scale the picture up to fill the frame, and the pointer, clicks, camera following and auto-zoom suggestions go through the same crop. A picture whose shape changed too is filled evenly with a small strip cut from two edges rather than stretched or left with a band. Tests: `PictureTrackingTests`, `PictureTrackTests`, `PictureCropTests`. Not yet seen on a real resized take in the app |

## Device frames and the canvas on a turned picture (2026-09-30)

| Problem | Cause and fix |
|---|---|
| No iPhone or iPad frame, only a macOS window and a browser — **fixed** | Two more kinds of the one window frame (`WindowChrome.Kind.iPhone`, `.iPad`, with a finish, an orientation and a camera switch, all decoded field by field so older projects open with none). Drawn in Core Image from rounded rectangles (`SceneRenderer+Device`): a coloured rim, black glass, a screen with the device's corner radius, the picture fitted inside it with black either side, and a camera pill over the top of a phone's screen or a lens in a tablet's bezel. The framing fits the whole handset inside the padding (`DeviceGeometry.bodySize`), the handset is the shadow caster and the plane the perspective turns, it grows with a whole-frame zoom and stays put for an inner one, and the border is not drawn on a device. Tests: `DeviceFrameRenderTests` (bezel, rim, black gaps, rounded body and screen corners, pill, lens, shadow, perspective, both zooms, a scaled preview), `DeviceFrameExportTests` (the handset is in an exported file), `DeviceFrameTests` in TimelineKit (old projects, unknown values, undo names, looks) |
| Canvas handles did not tilt with the Perspective look — **fixed** | The overlays drew every outline and grip on the flat picture, so on a turned one they sat beside what they belonged to. `PerspectiveProjection` now has an exact inverse (`unproject`, the projection written as one 3×3 matrix and inverted), and `SceneDescriptor` maps the finished frame and the recording both ways through it (`tiltedFramePoint`, `flatFramePoint`, `framePoint(forSource:)`, `sourcePoint(forFrame:)`, `tiltedFrameMatrix`). The editor's `CanvasTilt` lays that over the flat arithmetic: masks, annotations and the zoom framing box are drawn as their turned quadrilaterals, grips, knobs, a line's ends and a callout's tail sit on the turned points, the label being typed into is drawn through the same projection, and every drag is taken back through the inverse before the flat code sees it. Tests: `CanvasProjectionTests` (round trips of frame and recording points through crop, zoom and a device, the matrix against the point map, identity when flat). Not yet checked by eye in the app |
| The crop tool drew its handles over a picture still turned, or shrunk by a window bar | The crop tool's flat preview took away the padding, corners and camera but left the window frame and the perspective. It now takes those away too, so the picture under the crop handles is the whole recording, square-on |

## Known and not yet fixed

| Item | Notes |
|---|---|
| A device frame beside a camera layout's split | The handset is fitted round the picture's frame wherever a layout puts it, but the layouts size that frame for a bare picture, so a phone round half a split can reach into the other half. Not seen yet in a real project |
| RenderKit's video-reading tests could stall, even run alone — **fixed** | Stuck in `copyNextSampleBuffer`: the export reader held decoded frames in the decoder's own few buffers (the frame showing, the next one, and any still queued for the GPU), so the decoder ran out and waited for ever. The reader now copies each frame into a buffer of its own. Test: `framesHeldDoNotStallTheDecoder`. A real export could hang the same way |
| Camera background removal has not been checked on a real face | Only on synthetic frames |
| Caption translation has not been run end to end | The first use of a language can open the system's download sheet |
| Several recordings in one project, importing a video, iPhone and iPad recording, freehand annotations | Not built |
| The transcript's word picking, the font pickers, the export sheet's Target size and the safe-zone overlay have not been looked at on screen | Built and compiled with tests for the logic and the drawing; the views still need checking by eye, in light and dark |
| Text-field zooms only exist when keyboard shortcuts are recorded | Focus tracking of text fields is switched on with key capture. Worth separating |
| Results are never sent back to Klik | The helper service does not exist yet |
| One fidelity test failed once in about 20 full runs and has not failed since | Watching. It compares exact bytes while other tests render in parallel |
