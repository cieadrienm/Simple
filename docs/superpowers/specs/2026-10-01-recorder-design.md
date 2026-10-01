# Recorder in Simple Client — design

Date: 2026-10-01. Approved by Adrien in conversation ("Oui vas y").

## Goal

Simple Client records the Syphon source it displays to a movie file, encoding live, with a choice of
size, frame rate and bitrate — what Syphon Recorder does, without audio. Every function is reachable
from the window, over OSC (described by OSCQuery) and over MCP.

Out of scope: audio, HAP and Photo JPEG codecs, a global hot key, OSC feedback messages (status is
read through OSCQuery).

## What Adrien decided

- The recorder lives in Simple Client; Simple Server stays the test source.
- Video only.
- Private GitHub repository `cieadrienm/Simple`, mirrored to Gitea `amcb/Simple`.

## Decisions made for him (he was told, and did not object)

- Everything in the app is Objective-C. eMotion's `OSCQueryServer.m` is copied unchanged, so the two
  stay comparable. OSCScore has no OSCQuery server (only a browser); its MCP proxy is the model for ours.
- Bundle identifier becomes `net.am-cb.simple-client`: the current one belongs to the old app in
  `/Applications/Syphon Simple Apps`, and the Local Network permission is keyed on it.
- `Scripts/bundle.sh` builds the app, embeds the MCP tool and signs with the Apple Development
  identity, so the Local Network permission survives rebuilds.
- Default ports: OSC 9230 (UDP), OSCQuery 9231 (HTTP). Each scans upward if taken; the environment
  variables `SIMPLE_OSC_PORT` and `SIMPLE_OSCQUERY_PORT` override them (for a second instance).
- Codecs: H.264, HEVC, ProRes 422, ProRes 4444 (keeps alpha). Always a `.mov`.

## Layout

```
Recorder/            Objective-C, no Syphon dependency. Compiled into the app, and a SwiftPM target
                     (RecorderKit) so that `swift test` covers it without Xcode.
  FramePacer         which frames to keep for a frame rate cap, and their timestamps (pure)
  MovieRecorder      Metal texture → AVAssetWriter
  OSCMessage         OSC packet decoding and encoding
  OSCReceiver        UDP socket → messages on the main queue
  OSCQueryServer     from eMotion, unchanged
Simple Client/
  RecorderController settings, state, the parameter table shared by UI, OSC and OSCQuery
  RecorderSettingsViewController   the popover
MCP/main.swift       simple-recorder-mcp, stdio
Tests/RecorderKitTests
Package.swift        RecorderKit, its tests, simple-recorder-mcp
Scripts/bundle.sh
```

## Recording

A frame from `SyphonMetalClient` is an IOSurface-backed BGRA texture whose first row is the bottom of
the picture. For each frame kept by the pacer, `MovieRecorder` takes a pixel buffer from the asset
writer's pool, wraps it as a Metal texture (`CVMetalTextureCache`) and draws the frame into it: this
one render pass flips it, scales it to fit the output size without distortion (black bars, transparent
for ProRes 4444) and stays on the GPU. When the command buffer completes, the pixel buffer is appended
on the recorder's serial queue. Nothing here runs on the main thread: frames are taken in the Syphon
new-frame handler.

- **Size**: `width` × `height`, or the source's size when either is 0. Fixed when recording starts
  (the writer is created on the first frame); later frames of another size are scaled to fit.
  Dimensions are rounded down to even numbers.
- **Frame rate**: 0 keeps every frame, stamped with its arrival time. Otherwise frames are placed on
  a grid of 1/fps: frame *n* of the grid is the first to arrive in its slot, later ones in the same
  slot are discarded. If the source is slower, slots stay empty and the previous frame is held.
- **Bitrate**: megabits per second for H.264 and HEVC; 0 picks one from size and rate
  (0.1 bit per pixel per frame for H.264, 0.06 for HEVC). Ignored by ProRes.
- **Back-pressure**: a frame is discarded, and counted as dropped, when the writer is not ready for
  more data or when three frames are already waiting on the GPU.
- **File**: `<folder>/<name>.mov`; folder defaults to `~/Movies`, name to
  `<source application> yyyy-MM-dd HH.mm.ss`. An existing file is never overwritten (` 2`, ` 3`… is
  appended). Movie fragments are written every 10 s so a crash leaves a playable file.
- **Stopping**: waits for the frames in flight, ends the session at the elapsed time so the last frame
  lasts as long as it was shown, then finishes the file. Quitting while recording finishes the file
  first (`applicationShouldTerminate:` replies later).
- While recording, the app holds an activity assertion so App Nap and idle sleep do not throttle it.
- The source may be changed, or disappear and come back, while recording: the file simply receives
  whatever frames arrive. When the source which was chosen (in the menu or by `/source`) goes away, the
  selection falls back on another; when it is back, it is selected again.

## Parameters

One table in `RecorderController` defines every parameter once: address, type, range, description,
getter, setter. The window binds to the same properties.

| Address | Type | Access | Meaning |
|---|---|---|---|
| `/source` | s | rw | title of the source, as in the menu (`name - application`). `RANGE.VALS` lists the servers available. Setting matches the exact title, then a case-insensitive substring |
| `/record` | i | rw | 1 starts, 0 stops |
| `/record/toggle` | – | w | |
| `/codec` | s | rw | `h264`, `hevc`, `prores422`, `prores4444` |
| `/width`, `/height` | i | rw | 0 = source size |
| `/fps` | f | rw | 0 = source rate |
| `/bitrate` | f | rw | Mbit/s, 0 = automatic |
| `/folder`, `/name` | s | rw | empty name = automatic |
| `/status/state` | s | r | `idle`, `recording`, `finishing` |
| `/status/elapsed` | f | r | seconds |
| `/status/frames`, `/status/dropped` | i | r | |
| `/status/file` | s | r | file being written, or the last one written |
| `/status/error` | s | r | last error; cleared when a recording starts |
| `/status/failure` | s | r | why the last recording ended, if it failed or had nothing to write; a refused message does not change it |
| `/status/source/width`, `/height`, `/fps` | i, i, f | r | what the source delivers |

Numbers are accepted as int, float, double, or true/false. Settings changed while recording apply to
the next recording. Settings persist in user defaults.

OSCQuery is served by `OSCQueryServer` (HTTP GET, `HOST_INFO`, `VALUE`, `RANGE`), advertised over
Bonjour as `_oscjson._tcp`. Writing is done by OSC, as OSCQuery intends.

## MCP

`simple-recorder-mcp` is a stdio server embedded in the app bundle (`Contents/MacOS`). It reads through
OSCQuery and writes through OSC, so it exercises the same surface as any OSC controller. It finds the
app on port 9231 (or `SIMPLE_OSCQUERY_PORT`), scanning the next 15 ports for a `HOST_INFO` named
"Simple Client".

- `recorder_status` — sources available, selected source, settings, state, counters, file, error
- `recorder_configure {source?, codec?, width?, height?, fps?, bitrate?, folder?, name?}` — returns the status afterwards
- `recorder_start` — accepts the same settings; returns once the state is `recording`, or fails with `/status/error`
- `recorder_stop` — returns once the file is finished, with its path

## Window

The toolbar gains a record button (⌘R, also in the File menu) and a settings button opening a popover:
codec, size (presets and free fields), frame rate, bitrate, folder, name, and the OSC and OSCQuery
ports in use. While recording, the status box shows the elapsed time.

## Errors

Starting without a source, an unwritable folder, a writer which fails: the recording stops, the reason
goes to `/status/error` and to the status box. Nothing is silent. A refused message is shown for a few
seconds; why a recording ended (`/status/failure`) stays in the status box until the next recording. A
movie which has frames is never deleted: after a failure it can be played up to its last fragment.

Added after the review of the branch: `/status/failure`, the return to the chosen source, and the rule
that a frame for which no picture can be allocated is dropped rather than ending the recording.

## Tests

`swift test`: the pacer (kept frames and timestamps for sources faster and slower than the cap), OSC
decoding and encoding, the OSCQuery tree served over HTTP, the receiver over a local socket, and
`MovieRecorder` writing a short movie from synthetic textures, read back with AVFoundation (size,
duration, frame count, picture the right way up, alpha kept by ProRes 4444).

End to end, on the signed app with Simple Server running: drive it by OSC, then by MCP over stdio, and
read the files back.
