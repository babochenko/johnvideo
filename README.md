# John Video

A simple **native macOS video editor** written in **C** (engine) + **Objective-C++** (UI), using **FFmpeg** for decode/encode/mux. Timeline-based: images, text, video, multi-track audio with voiceover recording, and source-quality MP4 export. Liquid Glass UI, built with a plain Makefile against Homebrew FFmpeg.

---

## Build & run

```sh
make            # build  -> build/johnvideo.app  (display name "John Video")
make run        # build and launch the .app bundle (needed for the mic permission prompt)
make run-direct # run the raw binary (stderr logs; mic NOT granted this way)
make install    # copy to /Applications/John Video.app  (or: make install INSTALL_DIR="$HOME/Applications")
make clean      # remove build/
```

Requirements: macOS 26 (Tahoe) + Xcode 26 command-line tools (SDK 26), Homebrew `ffmpeg` (`brew install ffmpeg`). Apple Silicon.

> After editing **any header**, an incremental `make` rebuilds dependents automatically (`-MMD -MP`). If you ever pull changes and see a crash on load, do `make clean && make` once. The app icon comes from `icon.png` (→ `AppIcon.icns` at build time).

---

## Architecture

**The core constraint:** "native macOS" UI means AppKit, which is Objective-C — pure C cannot drive it. So the app is split:

- **Pure-C engine** (`src/engine/`) — data model, visual compositor, audio mixer, video decode, MP4 export. UI-agnostic.
- **Objective-C++ UI shell** (`src/ui/`, `.mm`) — windows, views, events. `.mm` lets one file freely mix Cocoa, the C engine, and FFmpeg's C APIs.

**Two pipelines are shared, one implementation each, two consumers:**
- `jv_render_frame()` — composites visual tracks at time *t*. Used by the **preview** and the **exporter**.
- `jv_mix_audio()` — sums audio tracks at time *t*. Used by **live playback** and the **exporter**.

This guarantees the preview matches the export.

### Stack

| Concern | Choice |
|---|---|
| UI shell | AppKit (Objective-C++) |
| Preview canvas | Core Graphics / NSImage (non-flipped view, top-down RGBA) |
| Text rendering | Core Text (rasterized to RGBA); in-place editor captures keystrokes directly (own caret), no `NSTextField` |
| Clipboard / drag-drop | NSPasteboard / NSDraggingDestination |
| Still images | ImageIO |
| Remote URL drops | NSURLSession |
| Video / audio import & decode | libavformat + libavcodec + libswscale + libswresample |
| Mic capture | AVFoundation (AVAudioEngine input tap) |
| Playback | AVAudioEngine + AVAudioSourceNode pulling `jv_mix_audio` |
| Encode + mux | libavcodec (H.264 + AAC) + libavformat |
| Liquid Glass | AppKit `NSGlassEffectView` (macOS 26 SDK) — **no Swift/Xcode migration** |

### Key decisions

- **Native AppKit, not GTK/Swift.** User wanted native macOS; the engine stays pure C and the UI is `.mm`.
- **Orientation settled empirically** (with probe programs in `test/`): RGBA buffers are **top-down**, the preview view is **non-flipped**, and `NSImage drawInRect:` draws them upright. Text and images share one convention.
- **Resolution independence:** the compositor sizes clips as a fraction of canvas **height** (aspect preserved) and positions them with normalized `(cx, cy)`. The canvas adopts the **first imported video's native resolution**, so a 1080p source exports at 1080p.
- **Liquid Glass is a system material** available to AppKit via `NSGlassEffectView` on the macOS 26 SDK — adopted without migrating off C/Obj-C++.
- **Export is lossless** (H.264 CRF 0) for source quality.
- **Undo/redo via deep-clone snapshots** of the whole timeline (`jv_timeline_clone`), recorded before each mutation.
- **Project file is plain text** (`.jvp`), git-trackable; path-less media (pasted images, recordings) saved to a sibling `<file>.assets/` folder.
- **Selection is a per-clip flag**, not a pointer set — it travels with the struct through array moves/reallocs/clones, which makes group move/copy safe.
- **In-place text editing captures keystrokes directly** (the preview is first responder) with its own caret — an overlaid `NSTextField` proved unreliable.
- **Makefile tracks header dependencies** (`-MMD -MP`): editing a header rebuilds every object that includes it. (Without this, fields added mid-struct left stale objects with mismatched layouts → heap corruption.)
- The on-disk bundle is `johnvideo.app`; the **display name is "John Video"** (Info.plist + window title + menu).

---

## Project layout

```
johnvideo/
├── Makefile                 # make / run / run-direct / clean -> build/johnvideo.app
├── Info.plist               # bundle metadata + NSMicrophoneUsageDescription
├── .gitignore               # build output, macOS cruft, *.assets/, exported media
├── README.md                # this file (full knowledge dump)
├── readme.json              # machine-readable context + tracked user requirements
├── icon.png                 # app icon source (→ AppIcon.icns at build time)
├── src/
│   ├── engine/              # pure C, UI-agnostic
│   │   ├── timeline.h/.c     # data model, compositor (jv_render_frame), mixer (jv_mix_audio),
│   │   │                     #   track ops (add/remove/move/order), deep clone
│   │   ├── decoder.h/.c      # FFmpeg: frame-at-time (seek+decode-forward) + read-all-audio
│   │   └── export.h/.c       # FFmpeg: composite+mix -> H.264/AAC -> MP4
│   └── ui/                   # Objective-C++ AppKit shell
│       ├── main.mm           # NSApplication entry + menus (App / File / Edit)
│       ├── AppDelegate.mm    # coordinator, EditorHost, RootView layout, toolbar,
│       │                     #   transport, recording, export, save/open, undo/redo, clipboard
│       ├── Editor.h          # EditorHost protocol + layout constants
│       ├── PreviewView.mm    # composited preview; canvas move/resize/rotate; in-place text edit;
│       │                     #   paste/drop; selection handles
│       ├── TimelineView.mm   # ruler, lanes, clips, waveforms; scrub/move/trim (both edges);
│       │                     #   track reorder; scroll/zoom; snapping; right-click menus
│       ├── Media.mm          # ImageIO load + Core Text rasterize + CGImage wrap
│       ├── AudioController.mm # AVAudioEngine playback + mic recording (live buffer)
│       └── Project.mm        # .jvp text save/load with sidecar PNG/WAV
└── test/                     # headless tests
    ├── test_export.c         # engine -> MP4 smoke test
    ├── test_orient.mm        # buffer orientation probe
    ├── test_display.mm       # NSImage display orientation probe
    └── test_project.mm       # .jvp save/load round-trip
```

---

## Data model (engine)

```c
Timeline { fps, width, height, Track[], playhead }
Track    { kind: VISUAL|AUDIO, name, Clip[] }
Clip     { type, start_time, duration, in_offset, union payload }
  IMAGE  { path, rgba, w, h, cx, cy, scale, rotation }
  TEXT   { string, font_size, color, rgba, w, h, cx, cy, scale, rotation }
  VIDEO  { path, decoder (lazy), cx, cy, scale, rotation }   // its audio is imported to an audio track
  AUDIO  { path, pcm (interleaved stereo float), frames, sample_rate, channels, gain }
```

- **Times** in seconds. `in_offset` is the trim into the source (left-edge trim).
- **Z-order:** the **first** visual track in the list is drawn **last** (on top). The compositor iterates tracks back-to-front.
- **Scale** = fraction of canvas height; **(cx, cy)** = normalized center (cy is top-down: 0 = top).
- **Rotation** in radians, clockwise.
- Tracks are kept ordered: **all visual tracks precede all audio tracks** (`jv_timeline_order_tracks`).

### Compositor & mixer

- `jv_render_frame` clears to opaque black, then for each active visual clip alpha-composites (premultiplied source-over) with **bilinear** sampling and **rotation** (inverse-mapped over the rotated bounding box).
- `jv_mix_audio` sums every overlapping audio clip, mapping timeline time → source sample by each clip's own `sample_rate` (so any rate mixes correctly), applying `gain`, soft-clipped to [-1, 1].

---

## Features

- **Images** — paste (Cmd+V), drag-drop from Finder or a **browser** (file URL / raw bytes / http URL fetched via NSURLSession), or Import. Decoded to top-down RGBA via ImageIO.
- **Text** — inserted **immediately** (no popup) and edited **in place on the preview** with a real caret; edits reflect live in the timeline clip label. Multiline (Return), full caret navigation (arrows), and clipboard (Cmd+A/C/X/V) while editing. Right-click "Add Text", press **t**, or **double-click** the canvas / a text clip.
- **Video** — imported and composited; a C decoder seeks and decodes forward to the playhead time, swscale → RGBA → CGImage. The video's embedded audio is imported onto an audio track.
- **Audio** — multiple tracks; **voiceover recording** against the playhead; **music import**. Waveforms drawn on clips.
- **Export** — composites all visual tracks + mixes all audio, encodes **H.264 (CRF 0, lossless) + AAC**, muxes to MP4. Runs on a background queue; a bottom-right toast shows a live elapsed timer, then the result with time taken and a click-to-open link.

Inserted **image and text clips are 1 s** long. Images (paste **and** Import) and pasted clips drop **after the last clip on the target track**, so repeated inserts line up one after another.

### Recording (voiceover)
- Hit **● Rec** → mic permission prompt (first time) → capture starts; the playhead advances from the capture clock.
- A **live clip grows on the Voiceover track in real time**, including its **waveform** (capture uses a fixed-capacity buffer so the pointer is stable; 10-minute cap).
- **■ Stop** finalizes the take in place (at the time recording started).

---

## Keyboard shortcuts

| Key | Action |
|---|---|
| Space | Play / stop (▶/⏸). At the end it holds on the last frame; pressing play again restarts from the start |
| ← / → | Move the playhead ∓ 0.5 s (does **not** pause playback — it keeps playing from the new spot) |
| h / l | Select previous / next clip on the current track (wraps) |
| j / k | Move focus down / up between tracks (wraps; **skips empty tracks**) |
| Cmd + A | Select **all** clips on all tracks (then drag or Option+←/→ to move them together) |
| Option + ← / → | Move the selected object(s) ∓ 0.5 s along the timeline |
| Cmd + H , Cmd + Opt + H | Standard macOS **Hide** / Hide Others |
| Cmd + ← / → | Jump the playhead through {start, markers…, end} (without pausing playback) |
| Ctrl + ← / → , Ctrl + h / l | Jump the playhead to the previous / next marker |
| m | Add a marker at the playhead |
| t | Add text at the playhead (enters in-place edit) |
| b | Toggle the blade tool (click a clip to split it at the click point) |
| Ctrl + `+` / `-` | Zoom timeline in / out |
| Delete / Backspace | Delete the marker at the playhead, else the selected clip (works on the preview too) |
| Cmd/Ctrl + C / V | Copy / paste clip (paste falls back to image from clipboard) |
| Cmd/Ctrl + Z / Shift + Z | Undo / redo |
| Cmd + S / Cmd + O | Save / Open project (after first save/open, Cmd+S saves in place silently) |
| Cmd + Shift + O | Reveal the current project in Finder |

**Selection**: click a clip to select it **and move the playhead to the click point**; clicking empty space **deselects**. **Cmd+click** toggles clips in/out of a multi-selection; **Shift+click** selects the range on that track between the anchor and the click; **Cmd+A** selects everything. Dragging any selected clip moves the whole selection together — horizontally, and vertically across same-kind tracks. The selection is a per-clip flag (survives moves/reallocs/clones); selection chrome only shows while the clip is visible at the playhead.

**Markers**: yellow flags on the timeline, **draggable** to reposition. Add with `m` or right-click the ruler → Add Marker Here; delete with Backspace at the playhead or right-click → Delete Marker; jump with Cmd+←/→ (incl. start/end) or Ctrl+←/→ / Ctrl+h/l; saved in the project (`mark <t>` lines); undoable.

**Editing text**: double-click a text clip on the **preview** or **timeline**. Editing happens in place on the preview — a caret shows and keystrokes edit live (reflected on the timeline). It starts with the whole string selected. **←/→** move the caret, **↑/↓** move between lines (keeping column), **Return** inserts a newline (multiline), **Esc** or clicking away commits. Clipboard: **Cmd+A** select all, **Cmd+C/X** copy/cut, **Cmd+V** paste at the caret, **Backspace** delete. Implemented by capturing keys directly (the preview is first responder), not an overlay field — so it's reliable, and arrow keys move the caret instead of being typed in.

**Blade tool**: press **B** to arm (or click the orange Liquid-Glass **Blade** chip, which only appears while armed, to disarm). With it armed, clicking a clip **splits it at the click point**; the cursor becomes a crosshair. Splits are ordinary clips, so they're saved in the project and undoable.

**Cursors**: the pointer shows a resize cursor over clip edges and markers, and resize/rotate cursors over the preview handles.

**Notifications**: a reusable bottom-right notification component (`JVNotification` — clickable body + ✕ close, self-sizing, stackable). Two modes via `presentNotification:fileURL:sticky:`. **Save** uses a transient toast that auto-fades. **Export** uses a **sticky** one: a live elapsed timer while encoding, then `Exported <name> at HH:mm:ss (Ns) — click to view` that **stays until clicked or dismissed with the ✕**.

---

## Timeline interactions

- **Scrub** by clicking/dragging the ruler or empty lanes; the playhead **snaps** to clip boundaries (and 0). The ruler tick step **auto-scales with zoom** (1s → 2/5/10/15/30s → 1/2/5/10/30/60 min).
- **Click a clip** to select it and move the playhead to the click point; **click empty space** to deselect.
- **Move** a clip by dragging; **trim** by dragging either edge (left edge trims into the source). All are **sticky** — they snap to the playhead and to neighbouring clips' edges. A **grabbing cursor** shows while dragging.
- **Move between tracks** by dragging a clip vertically onto another same-kind track (group-moves all selected).
- **Reorder tracks** by dragging a track header up/down (video stays above audio).
- **Zoom**: pinch, or Option/Cmd-scroll, or Ctrl +/-. Zoom is **anchored around the cursor** — pinch/scroll keep the time under the mouse pointer fixed; Ctrl +/- keep the playhead fixed. **Scroll**: horizontal pans time, vertical moves the track list. Zoom + scroll + playhead are saved in the project.
- **Right-click**: on a clip → Delete (audio clips also get a **Volume** slider, 0–400%, live); on empty lane → Add Text Here; on the ruler → Add/Delete Marker; on a track header → Add Video/Audio Track, **Rename Track…**, Delete This Track (**with confirmation** warning that media disappears).
- **Audio volume**: every audio clip carries a per-clip `gain`; right-click it for a 0–400% volume slider (clamped, undoable, applied live by the mixer). The current level shows as a `NN%` badge on the clip.
- **Floating toolbar**: separate rounded Liquid Glass capsule buttons overlay the bottom of the timeline (no reserved space, not movable). The orange **Blade** chip appears to the left only while the blade tool is armed.

## Canvas (preview) interactions

- **Move** a clip by dragging; sticky to canvas **edges** and **center**.
- **Resize** via the bottom-right handle; **rotate** via the top handle (snaps to multiples of 90°). Selection chrome rotates with the clip.
- **Crop (trim) an image**: with an image selected, click the **crop button at its top-right**. A dashed frame appears over the full image — drag its interior to move it, drag a corner to resize. **Esc or the crop button again** approves. Crop is **non-destructive** (it reduces the displayed area only, never alters the bitmap), honored identically by preview and export, and saved in the project (`cropx/cropy/cropw/croph` on the image clip).
- **Right-click / double-click** to add or edit text in place.

---

## Project file format (`.jvp`)

Plain text, line-based, git-diff friendly. Hierarchical: clips indented 2 spaces, their sublines 4, a blank line after each track (indentation and blanks are **ignored** by the parser). Media with a source file is referenced by path; path-less media (pasted images, recordings) is written into a sibling `<file>.assets/` folder (PNG / 16-bit WAV) and referenced relatively.

```
johnvideo 1
canvas 1280 720 25.0000
zoom 20.0000
playhead 1.5000
scroll 0.0000 0.0000
mark 3.4631
track V Video 1
  clip text start=1.0000 dur=1.0000 in=0.0000 cx=0.5000 cy=0.4000 scale=0.0000 rot=0.3000 font=64.0000 color=0xFFFFFFFF
    str Hello\nWorld
  clip image start=0.0000 dur=1.0000 in=0.0000 cx=0.3000 cy=0.3000 scale=0.6000 rot=0.0000
    asset project.jvp.assets/img0.png

track A Music
  clip audio start=0.0000 dur=5.0000 in=0.0000 gain=1.0000 rate=48000
    src /Users/me/music.mp3
```

- Clip fields are labeled `key=value`, parsed order-independently: `start dur in` for every clip; image/video add `cx cy scale rot`; text adds `font color`; audio adds `gain rate`.
- Top-level optional lines: `zoom <pps>`, `playhead <t>`, `scroll <x> <y>`, `mark <t>` — so reopening restores the full view state.
- The `str` value escapes `\` and newlines (`\n`), so **multiline text** stays on one line on disk and round-trips.
- The per-clip selection flag is transient and **not** saved.

---

## Requirements (all delivered)

All tracked user requests are implemented; the machine-readable list with per-item notes lives in **`readme.json`**. Grouped summary:

- **Core:** native C+FFmpeg app, Makefile, Homebrew; paste/drag-drop images (incl. browser); right-click text; video import; multi-track audio; voiceover; music; MP4 export.
- **Playback/timeline:** wall-clock transport, time readout, playhead boundary snap, take placed at record start, horizontal zoom, sticky clip move/trim (both edges), add/remove tracks, move clips between tracks, track reorder, video-above-audio, top-track z-order, horizontal/vertical scroll, delete-track confirmation.
- **Canvas:** upright images & text, move, resize, rotate (90° snap), canvas-edge snap.
- **Audio:** live playback (incl. recorded voiceover), live recording waveform.
- **Look:** Liquid Glass (no Swift), floating rounded glass buttons, bright labels/time, dark window (no white line).
- **Export:** bilinear compositing, source-resolution canvas, lossless CRF 0.
- **Text:** insert immediately, in-place cursor editing, live timeline reflection, double-click edit.
- **Editing:** copy/paste clip, undo/redo, keyboard shortcuts (space, arrows, h/l, t, Ctrl +/-).
- **Project:** save/open git-trackable `.jvp`, sidecar assets, hierarchical format, `.gitignore`.

---

## Known caveats

- **Lossless export (CRF 0)** produces large files and slower encodes. Can be dialed to a visually-lossless CRF (~12) for sane sizes on request.
- **Live audio playback** is verified to produce sound via the proven mixer (export path), but the live `AVAudioEngine` output could not be confirmed in a headless environment — **verify on device**. If silent, run `make run-direct` and check Console for `johnvideo: play engine …`.
- **Resize/rotate handle hit-areas** use the unrotated position, so grabbing handles on a heavily rotated clip is approximate.
- **Editing during playback** is not locked against the audio render thread (fine for single-user editing; benign for the live-recording waveform read).
- **Video decode** is single-threaded, decode-on-demand at the playhead; fast scrubbing of long clips may stutter.
- **Project media** with real source files is referenced by absolute path; moving those files breaks the reference (sidecar assets are relative and safe).
- **Recording** is capped at 10 minutes per take (fixed-capacity capture buffer).

---

## Tests (headless)

> **Policy: every change must be tested.** Any behaviour change ships with a
> test that covers it — extend `test/test_ui.mm` for UI/interaction behaviour
> (synthesize the events, assert on the model), the engine/project suites for
> non-UI logic. `make test` must pass before committing. If something genuinely
> can't be unit-tested headlessly (live audio, mic, network, on-screen pixels),
> say so explicitly in the change and note how it was verified instead.

```sh
make test          # run every suite (engine + project round-trip + UI)
make test-ui       # UI behaviour suite (synthesizes events into real views)
make test-export   # engine -> MP4 (compositor + mixer + encode/mux)
make test-project  # .jvp save/load round-trip
```

Each suite is its own `test/*.{c,mm}` with its own `main()`; the Makefile links
every app object except `main.o`. `make test` is the gate — every suite returns
a non-zero exit on failure.

### Manual probe builds (orientation)

```sh
# engine -> MP4 (compositor + mixer + encode/mux) — same as `make test-export`
clang test/test_export.c build/obj/engine/*.o $(pkg-config --cflags --libs libavformat libavcodec libavutil libswscale libswresample) -o build/test_export

# orientation probes and .jvp round-trip are .mm; link Cocoa + Project.mm/Media.mm as needed
```

**UI behaviour tests** (`test/test_ui.mm`, run with `make test-ui`) boot a real `AppDelegate` (the real `EditorHost`) with real `TimelineView`/`PreviewView` in an offscreen window, then **synthesize `NSEvent`s** (mouse, keyboard, scroll-wheel via `CGEvent`) and assert on the resulting model/transport state. This exercises the genuine `mouseDown/Dragged/Up` and `keyDown` state machines headlessly — no GUI session needed. Test-only hooks live in `AppDelegate+Test.h` / `PreviewView+Test.h` (small categories that expose private state + an offscreen boot; not compiled into the app's `main`).

Covered (104 assertions): scrub/seek and redline play-state (incl. scrub-while-playing), click-vs-drag, both edge trims, clip move across tracks, snapping (scrub-to-edge, move-to-neighbour), selection (single / Cmd / Shift / Cmd+A / click-empty deselect / group nudge), keyboard transport & navigation (Space, arrows, h/l, j/k, Option+arrows to move clips, Cmd/Ctrl arrows, t, m, b, Delete), markers (add/drag/delete/jump), blade (arm/cut/disarm), zoom (Ctrl +/−), scroll panning, track add/remove/reorder, playhead-follow paging, **project save + reopen-on-launch**, in-place text editing (typing, select-all, backspace, newline, Esc-commit, Cmd+A/X/V, double-click-to-edit, and the notes-app caret nav: plain / Cmd / Option + arrows), and canvas move / resize / rotate (90° snap) / empty-click deselect.

**Deliberately *not* unit-tested** (each needs hardware, network, a real render target, or a GUI session — verify on device): live `AVAudioEngine` output, mic/voiceover capture, http(s) image-drop fetches, drag-and-drop from external apps, and actual on-screen pixel rendering (the engine compositor itself is covered by `test-export`; orientation by the probes below). Pinch-zoom uses the same code path as Ctrl +/− and scroll-zoom (`magnification` can't be synthesized).

`make` first to produce `build/obj/engine/*.o`. The orientation probes (`test_orient.mm`, `test_display.mm`) document why the preview is non-flipped with top-down buffers. Pattern for ad-hoc tests: write a small `.mm` that includes `Project.h`/`timeline.h`, compile it linking `src/ui/Project.mm src/ui/Media.mm build/obj/engine/timeline.o build/obj/engine/decoder.o` + Cocoa/ImageIO/CoreText/CoreGraphics + the ffmpeg libs.

---

## Orientation for the next session (read this first)

**What this is:** a working, single-window macOS timeline editor. Engine in C, UI in Obj-C++. No app sandbox, no code signing, no Xcode project — just the Makefile.

**Mental model / where things live**
- All editor actions funnel through the **`EditorHost` protocol** (`Editor.h`), implemented by `AppDelegate`. The two views (`PreviewView`, `TimelineView`) hold a weak `host` and call it; they never touch each other.
- The **engine never knows about AppKit**; the UI never re-implements compositing/mixing — it calls `jv_render_frame` / `jv_mix_audio`.
- **Coordinates:** clip position is normalized `(cx, cy)`, `cy` top-down (0 = top). `scale` = fraction of canvas height. The preview view is **non-flipped** and draws the top-down RGBA via `NSImage` (this combination was verified by probe tests — don't "fix" it without re-checking).
- **Selection** = a per-clip `selected` flag in the struct (not a pointer set). `_selected` in AppDelegate is just the *primary*. Group ops iterate the flag.
- **Transport** is wall-clock (`NSProcessInfo.systemUptime`) in AppDelegate, independent of the audio engine, so the playhead moves even if audio fails.

**Sharp edges that already bit us (don't repeat)**
- **Adding a field mid-struct** to `jv_clip`/`jv_timeline` is safe *only* because the Makefile now tracks header deps (`-MMD -MP`). If you change the build rules, keep that or stale objects will corrupt memory.
- **Text in-place editing** is hand-rolled keystroke capture (the preview is first responder), with its own caret index. Arrow keys are in the function-key Unicode range (≥0x20) — filter them or they get typed in. `NSTextField` overlays were tried and were unreliable.
- **`NSStringDrawing` multiline orientation** is fiddly; `jv_rasterize_text` draws each line by hand to guarantee top-down. Verified with a probe.
- **AVAudioSourceNode** must use the **output's** format (sample rate + interleaved-ness) and set `*silence = NO`, or playback is silent.
- **Project `str` values** escape `\` and `\n` (line-based format). Anything line-based must escape newlines.
- **Cmd+C/V/Z** are Edit-menu key equivalents → they reach `copy:`/`paste:`/`undo:` (handled on the views/host), *not* `keyDown:`. Cmd+A/X and bare keys reach `keyDown:`.

**To resume:** `make && make run`. Check `git log` for recent direction; `readme.json` has the per-feature request log. Open `/Users/<you>/Movies/.../project.jvp`-style files via Cmd+O. When in doubt about a render/orientation question, write a headless probe (see Tests) rather than eyeballing the GUI.
