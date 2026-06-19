# johnvideo

A simple native macOS video editor written in C, using FFmpeg for decode/encode/mux.

## Goal

A lightweight timeline-based editor that can:

- **Images** — copy-paste into the timeline, or drag-and-drop from anywhere, including directly from a web browser.
- **Text** — add directly into the timeline or preview at any point by right-clicking.
- **Video** — import video clips, trim, and arrange on the timeline.
- **Audio** — record voiceovers against playback and import background music, across multiple audio tracks.
- **Export** — render the whole timeline to a single MP4 with audio.

## User requirements (tracked)

Everything the user has explicitly asked for, with status. ✅ done · 🔲 outstanding.

**Core editor**
- ✅ Native macOS app in C + FFmpeg, built with a Makefile against Homebrew FFmpeg
- ✅ Copy-paste images into the timeline (Cmd+V)
- ✅ Drag-and-drop images from anywhere, including a browser (file / raw bytes / URL fetch)
- ✅ Add text by right-clicking the preview or the timeline
- ✅ Import & composite video clips
- ✅ Record voiceovers; import music; multiple audio tracks
- ✅ Export the timeline to an MP4 with audio

**Playback & timeline**
- ✅ Play/pause transport with a moving playhead (wall-clock driven)
- ✅ Current time readout (m:ss.mmm)
- ✅ Playhead snaps to clip boundaries when scrubbing
- ✅ Recorded take is placed at the time recording started (not where it stopped)
- ✅ Make the timeline horizontally zoomable (pinch, or Option/Cmd-scroll)
- ✅ Snap clips to the playhead and to other clips' boundaries when moving/trimming (sticky)
- ✅ Add and remove video/audio tracks (right-click a track header)
- ✅ Move clips between tracks (drag vertically onto a same-kind track)

**Canvas (preview) editing**
- ✅ Pasted/dropped images appear upright
- ✅ Resize and rotate images (and other visual clips) on the canvas (selection handles)
- ✅ Move clips around the canvas

**Audio**
- ✅ Recorded voiceover audible during in-app playback (explicit mixer→output path) — verify on device
- ✅ Show a waveform of recorded audio on its timeline clip

**Look & feel (Liquid Glass)**
- ✅ Adopt Liquid Glass without migrating to Swift/Xcode (AppKit `NSGlassEffectView`, macOS 26 SDK)
- ✅ Floating bottom toolbar with individual Liquid Glass buttons (merged in a glass container)
- ✅ Brighter track labels (Video 1/2, Voiceover, Music) and time counter

**Export quality**
- ✅ Bilinear compositing + canvas adopts the first imported video's native resolution
- ✅ Export at source quality (lossless H.264, CRF 0)

## Architecture

The most important constraint: **"native macOS" UI means AppKit, which is Objective-C — pure C cannot drive it.** So the app is split:

- **Pure-C engine** — timeline/data model, audio mixer, video decode module, export pipeline.
- **Objective-C++ (`.mm`) UI shell** — windows, views, events. `.mm` lets a single file mix Cocoa, the C engine, and FFmpeg's C APIs freely.

The C engine is UI-agnostic; AppKit is used only for windows, views, and event handling.

**Key design decision:** FFmpeg is only required at *export* time for output, and for *video import* in the edit layer. Live editing/preview of images and text uses native macOS 2D APIs — no encode/decode on every interaction.

## Stack

| Concern | Choice |
|---|---|
| UI shell | AppKit (Objective-C++) |
| Preview canvas | Core Graphics / CALayer |
| Text rendering | Core Text (NSAttributedString) |
| Clipboard + drag-drop | NSPasteboard / NSDraggingDestination |
| Still images | ImageIO / NSImage |
| Remote URL drops | NSURLSession |
| Video import/decode | libavformat + libavcodec + libswscale → CGImage |
| Mic capture | AVFoundation (AVCaptureSession); miniaudio as fallback |
| Encode + mux | libavcodec (H.264 + AAC) + libavformat |

## Build

- **Build system:** plain **Makefile** producing a macOS `.app` bundle.
- **FFmpeg source:** **Homebrew** (`brew install ffmpeg`); link against Homebrew's libav* libraries.

## Data model

```
Timeline { fps, w, h, Track[] }
Track    { kind: VISUAL|AUDIO, name, Clip[] }
Clip     { type, start_time, duration, in_offset }   // in_offset = trim into source
  IMAGE  { cgimage, x, y, scale }
  TEXT   { attributed_string, x, y }
  VIDEO  { source_path, decoder_handle, x, y, scale }   // has its own audio too
  AUDIO  { wav_path, sample_rate, channels, gain }
```

- Multiple tracks of each kind.
- `in_offset` + `duration` give trimming.
- Z-order for visuals = track order.
- All audio tracks sum in the mixer with per-clip `gain`.

## Feature notes

### Images (paste & drag-drop)
Handle each incoming pasteboard flavor:
- File path / file URL (local file, or browser "drag image") → load via ImageIO.
- Remote `http(s)://` URL → fetch via NSURLSession.
- Raw image data (`public.png` etc., e.g. clipboard paste) → decode from memory.

Result becomes an IMAGE clip dropped at the cursor position. Ctrl/Cmd+V uses the same handler.

### Text (right-click)
Right-click on the timeline or preview → context menu "Add text." Click position maps to (track + time) on the timeline, or (x,y) on the preview frame. Creates a TEXT clip with an inline editor; rendered live with Core Text.

### Video import (the hardest part — edit layer, not just export)
A C decoder module wraps one source file and answers "give me the frame at time T":
- Open file, find video stream, seek to nearest keyframe before T, decode forward to T.
- swscale → RGBA → CGImage for preview.
- Cache last decoded frame; decode on a background thread so scrubbing stays responsive.
- The clip's embedded audio is extracted to PCM and treated as an AUDIO source during mixing.

### Audio (voiceover + music, multi-track)
- **Mixer:** at time T, sum PCM from every overlapping AUDIO clip (voiceover, music, video-clip audio) applying per-clip gain. Used for both live playback and export.
- **Voiceover:** record-against-playback — playhead plays, mic captures via AVFoundation → temp WAV → AUDIO clip on a voiceover track.
- **Music:** import an audio file (drag-drop / file picker) as an AUDIO clip on a music track; trim/move like any clip.

### Export
Per output frame: composite all visual tracks (z-ordered) → swscale → H.264 encoder.
In parallel: mix all audio tracks → AAC encoder.
Interleave both streams into one MP4 by PTS. Most FFmpeg fiddliness (timestamps, interleaving) lives here.

## Build phases — all complete

1. ✅ **Skeleton** — `.app` bundle, Makefile linking AppKit + ffmpeg (Homebrew), preview + timeline panes, C-engine / Obj-C++ split.
2. ✅ **Engine + preview** — data model, compositor renders visuals at the playhead into a CGImage.
3. ✅ **Images + text** — paste (Cmd+V), drag-drop (local file → browser image → URL fetch via NSURLSession), right-click "Add Text".
4. ✅ **Video import** — FFmpeg decoder module (seek + decode-forward), video clips composited in preview.
5. ✅ **Multi-track timeline** — track lanes, time ruler, scrub, clip select / move / trim, delete.
6. ✅ **Audio playback + mixer** — AVAudioSourceNode pulls the C mixer; all audio tracks summed, synced to visual refresh.
7. ✅ **Voiceover + music** — AVFoundation mic capture (record-against-playback) → audio clip; music/video audio imported via the decoder.
8. ✅ **Export** — composite all visual tracks + mix all audio tracks, encode H.264 + AAC, mux to MP4.

## Project layout

```
johnvideo/
├── Makefile                 # make / make run / make clean  →  build/johnvideo.app
├── Info.plist               # bundle metadata + mic-usage string
├── src/
│   ├── engine/              # pure C, UI-agnostic
│   │   ├── timeline.[ch]     # data model + compositor (jv_render_frame) + mixer (jv_mix_audio)
│   │   ├── decoder.[ch]      # FFmpeg: frame-at-time + read-all-audio
│   │   └── export.[ch]       # FFmpeg: composite+mix → H.264/AAC → MP4
│   └── ui/                  # Objective-C++ AppKit shell
│       ├── main.mm           # NSApplication entry
│       ├── AppDelegate.mm    # coordinator + EditorHost + toolbar + actions
│       ├── Editor.h          # EditorHost protocol + layout constants
│       ├── PreviewView.mm    # composited preview, right-click text, paste/drop
│       ├── TimelineView.mm   # ruler, lanes, clips, scrub/move/trim, drops
│       ├── Media.mm          # ImageIO load + Core Text rasterize + CGImage wrap
│       └── AudioController.mm # AVAudioEngine playback + mic recording
└── test/test_export.c       # headless engine smoke test (no GUI)
```

## Usage

```
make run        # build and launch
```

- **Add images**: drag from Finder or a browser onto the preview/timeline, paste with Cmd+V, or "Add Image…".
- **Add text**: right-click the preview (placed where you click) or a timeline lane → "Add Text Here".
- **Import video / music**: "Import…" (or drag a file in). Video goes to a visual track; its audio + standalone music go to audio tracks.
- **Voiceover**: position the playhead, click **● Rec** — the timeline plays while the mic records; click **■ Stop** to drop the take on the Voiceover track.
- **Edit**: drag a clip to move it, drag its right edge to trim, press Delete to remove. Scrub by clicking the ruler.
- **Export**: **Export…** → choose a path → renders the timeline to MP4.

## Architecture-as-built notes

- **Resolution independence**: the compositor sizes clips as a fraction of canvas height (aspect preserved) and positions them with normalized (cx, cy), so the small live preview and the full-res export match.
- **Shared pipelines**: preview and export both call `jv_render_frame`; playback and export both call `jv_mix_audio`. One implementation, two consumers.
- **Threading**: the audio render block reads the timeline on the audio thread and export runs on a background queue. Mutating clips during playback is not yet locked — fine for interactive single-user editing, a known sharp edge.
