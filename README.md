# johnvideo

A simple **native macOS video editor** written in **C** (engine) + **Objective-C++** (UI), using **FFmpeg** for decode/encode/mux. Timeline-based: images, text, video, multi-track audio with voiceover recording, and source-quality MP4 export. Liquid Glass UI, built with a plain Makefile against Homebrew FFmpeg.

---

## Build & run

```sh
make            # build  -> build/johnvideo.app
make run        # build and launch the .app bundle (needed for the mic permission prompt)
make run-direct # run the raw binary (stderr logs; mic NOT granted this way)
make clean      # remove build/
```

Requirements: macOS 26 (Tahoe) + Xcode 26 command-line tools (SDK 26), Homebrew `ffmpeg` (`brew install ffmpeg`). Apple Silicon.

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
| Text rendering | Core Text (rasterized to RGBA) + in-place `NSTextField` editor |
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

---

## Project layout

```
johnvideo/
├── Makefile                 # make / run / run-direct / clean -> build/johnvideo.app
├── Info.plist               # bundle metadata + NSMicrophoneUsageDescription
├── .gitignore               # build output, macOS cruft, *.assets/, exported media
├── README.md                # this file (full knowledge dump)
├── readme.json              # machine-readable context + 58 tracked requirements
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
- **Text** — inserted **immediately** (no popup) and edited **in place on the preview with a cursor** (overlaid `NSTextField`); edits reflect live in the timeline clip label. Right-click "Add Text", press **t**, or **double-click** the canvas / a text clip.
- **Video** — imported and composited; a C decoder seeks and decodes forward to the playhead time, swscale → RGBA → CGImage. The video's embedded audio is imported onto an audio track.
- **Audio** — multiple tracks; **voiceover recording** against the playhead; **music import**. Waveforms drawn on clips.
- **Export** — composites all visual tracks + mixes all audio, encodes **H.264 (CRF 0, lossless) + AAC**, muxes to MP4. Runs on a background queue with a progress sheet.

### Recording (voiceover)
- Hit **● Rec** → mic permission prompt (first time) → capture starts; the playhead advances from the capture clock.
- A **live clip grows on the Voiceover track in real time**, including its **waveform** (capture uses a fixed-capacity buffer so the pointer is stable; 10-minute cap).
- **■ Stop** finalizes the take in place (at the time recording started).

---

## Keyboard shortcuts

| Key | Action |
|---|---|
| Space | Play / stop (▶/⏸). At the end it holds on the last frame; pressing play again restarts from the start |
| ← / → | Move the playhead ∓ 0.5 s |
| h / l | Select previous / next clip on the current track (wraps) |
| j / k | Move focus down / up between tracks (j wraps to top, k to bottom; defaults top/bottom) |
| Cmd + h / l | Move the selected object(s) ∓ 0.5 s along the timeline |
| Cmd + ← / → | Jump the playhead through {start, markers…, end} |
| Ctrl + ← / → , Ctrl + h / l | Jump the playhead to the previous / next marker |
| m | Add a marker at the playhead |
| t | Add text at the playhead (enters in-place edit) |
| Ctrl + `+` / `-` | Zoom timeline in / out |
| Delete / Backspace | Delete the marker at the playhead, else the selected clip (works on the preview too) |
| Cmd/Ctrl + C / V | Copy / paste clip (paste falls back to image from clipboard) |
| Cmd/Ctrl + Z / Shift + Z | Undo / redo |
| Cmd + S / Cmd + O | Save / Open project |

**Selection**: click a clip to select; **Cmd+click** to toggle multiple into the selection — dragging any of them moves them all together.

**Markers**: yellow flags on the timeline, **draggable** to reposition. Add with `m` or right-click the ruler → Add Marker Here; delete with Backspace at the playhead or right-click → Delete Marker; jump with Cmd+←/→ (incl. start/end) or Ctrl+←/→ / Ctrl+h/l; saved in the project (`mark <t>` lines); undoable.

**Editing text**: double-click a text clip on the **preview** or **timeline**. Editing happens in place on the preview — a caret shows and keystrokes/backspace edit live (reflected on the timeline); Return/Esc commits. (Implemented by capturing keys directly, not an overlay field.)

**Cursors**: the pointer shows a resize cursor over clip edges and markers, and resize/rotate cursors over the preview handles.

---

## Timeline interactions

- **Scrub** by clicking/dragging the ruler or empty lanes; the playhead **snaps** to clip boundaries (and 0).
- **Move** a clip by dragging; **trim** by dragging either edge (left edge trims into the source). All are **sticky** — they snap to the playhead and to neighbouring clips' edges.
- **Move between tracks** by dragging a clip vertically onto another same-kind track.
- **Reorder tracks** by dragging a track header up/down (video stays above audio).
- **Zoom**: pinch, or Option/Cmd-scroll, or Ctrl +/-. **Scroll**: horizontal pans time, vertical moves the track list.
- **Right-click**: on a clip → Delete; on empty lane → Add Text Here; on a track header → Add Video/Audio Track, Delete This Track (**with confirmation** warning that media disappears).
- **Floating toolbar**: separate rounded Liquid Glass capsule buttons overlay the bottom of the timeline (no reserved space, not movable).

## Canvas (preview) interactions

- **Move** a clip by dragging; sticky to canvas **edges** and **center**.
- **Resize** via the bottom-right handle; **rotate** via the top handle (snaps to multiples of 90°). Selection chrome rotates with the clip.
- **Right-click / double-click** to add or edit text in place.

---

## Project file format (`.jvp`)

Plain text, line-based, git-diff friendly. Hierarchical: clips indented 2 spaces, their sublines 4, a blank line after each track (indentation and blanks are **ignored** by the parser). Media with a source file is referenced by path; path-less media (pasted images, recordings) is written into a sibling `<file>.assets/` folder (PNG / 16-bit WAV) and referenced relatively.

```
johnvideo 1
canvas 1280 720 25.0000
track V Video 1
  clip text start=1.0000 dur=3.0000 in=0.0000 cx=0.5000 cy=0.4000 scale=0.0000 rot=0.3000 font=64.0000 color=0xFFFFFFFF
    str Hello World
  clip image start=0.0000 dur=2.0000 in=0.0000 cx=0.3000 cy=0.3000 scale=0.6000 rot=0.0000
    asset project.jvp.assets/img0.png

track A Music
  clip audio start=0.0000 dur=5.0000 in=0.0000 gain=1.0000 rate=48000
    src /Users/me/music.mp3
```

Clip fields are labeled `key=value` and parsed order-independently: `start dur in` for every clip; image/video add `cx cy scale rot`; text adds `font color`; audio adds `gain rate`.

---

## Requirements (all delivered)

All 58 tracked user requests are implemented; the machine-readable list with per-item notes lives in **`readme.json`**. Grouped summary:

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

```sh
# engine -> MP4 (compositor + mixer + encode/mux)
clang test/test_export.c build/obj/engine/*.o $(pkg-config --cflags --libs libavformat libavcodec libavutil libswscale libswresample) -o build/test_export

# orientation probes and .jvp round-trip are .mm; link Cocoa + Project.mm/Media.mm as needed
```

`make` first to produce `build/obj/engine/*.o`. The orientation probes (`test_orient.mm`, `test_display.mm`) document why the preview is non-flipped with top-down buffers.
