Simple
======

Simple Client and Simple Server demo and testbed applications for [Syphon](https://github.com/Syphon/Syphon-Framework).

- **Simple Server** publishes an animated test pattern (a pulsing background, a bar which sweeps across the frame and a marker in the top left corner). Resize its window to change the size of the frames it publishes.
- **Simple Client** displays the frames of any Syphon server, and records them to a movie. It can be driven from its window, by OSC (described by OSCQuery) and by MCP.

Both render with Metal (`SyphonMetalServer` and `SyphonMetalClient`).

Recording
---------

Choose a source in the toolbar, then press the record button (or File ▸ Start Recording, ⌘R). Press it again to stop: the movie is in `~/Movies`, named after the source's application and the date. The gear button opens the settings:

- **Codec**: H.264, HEVC, ProRes 422 or ProRes 4444 (which keeps transparency). Movies are always `.mov`.
- **Size**: the source's, or a size of your choice. The picture is scaled to fit without distortion, with black bars (transparent for ProRes 4444). The size is fixed when the recording starts.
- **Frame rate**: every frame of the source, or a maximum. Above the maximum, frames in excess are discarded and those kept are evenly timed.
- **Bitrate**: megabits per second for H.264 and HEVC, or automatic. ProRes has none to choose.
- **Folder** and **Name**. An existing movie is never overwritten: a number is added to the name.

Frames are scaled and encoded on the GPU, away from the main thread. If the encoder cannot keep up frames are dropped, and counted, rather than delaying anything. Quitting, closing the window or `kill` while recording finishes the movie first. If writing fails (a full disk, for instance) the recording stops, the reason stays in the window until the next recording, and what was written is kept.

The source can be changed while recording. If the source's application quits, the movie holds its last frame; when it is back, Simple Client returns to it.

OSC and OSCQuery
----------------

Simple Client listens for OSC on UDP port **9230** and describes its parameters to OSCQuery clients on HTTP port **9231**, announced by Bonjour (`_oscjson._tcp`). If a port is taken the next free one is used; the settings popover shows the ports in use. `SIMPLE_OSC_PORT` and `SIMPLE_OSCQUERY_PORT` in the environment choose other ports, to run a second copy.

| Address | Type | | |
|---|---|---|---|
| `/source` | string | read, write | The source: its title as in the menu, or part of it. OSCQuery lists the sources available as its `RANGE`. |
| `/record` | int | read, write | 1 starts recording, 0 stops and finishes the movie |
| `/record/toggle` | – | write | Starts, or stops |
| `/codec` | string | read, write | `h264`, `hevc`, `prores422`, `prores4444` |
| `/width`, `/height` | int | read, write | 0 for the size of the source |
| `/fps` | float | read, write | 0 for every frame of the source |
| `/bitrate` | float | read, write | Megabits per second, 0 for automatic |
| `/folder`, `/name` | string | read, write | An empty name is the source's application and the date |
| `/status/state` | string | read | `idle`, `recording`, or `finishing` while the movie is completed |
| `/status/elapsed` | float | read | Seconds recorded |
| `/status/frames`, `/status/dropped` | int | read | Frames written, and lost because the encoder could not keep up |
| `/status/file` | string | read | The movie being written, or the last one written |
| `/status/error` | string | read | The last error: a message which was refused, a recording which could not start or failed. Empty when a recording starts. |
| `/status/failure` | string | read | Why the last recording ended, if it failed or had nothing to write. Empty otherwise. |
| `/status/source/width`, `/height`, `/fps` | int, int, float | read | What the source delivers |

OSC has no passwords: any machine which can reach Simple Client's port can start and stop recordings and change where they are written. Use it on a network you trust.

Numbers are accepted as int or float. Settings are saved, and apply to the next recording. A message which cannot be applied is reported in `/status/error` and, for a few seconds, in the window.

    Tools/osc-send.py 9230 /codec hevc
    Tools/osc-send.py 9230 /record 1
    curl 'localhost:9231/status/state?VALUE'

MCP
---

`Scripts/bundle.sh` puts `simple-recorder-mcp` inside Simple Client (`Contents/MacOS`). It is a stdio MCP server which reads the recorder through OSCQuery and writes with OSC, so the app must be running. `.mcp.json` declares it for Claude Code, from `build/Simple Client.app`.

- `recorder_status`: sources, settings, state, counters, file, error
- `recorder_configure {source, codec, width, height, fps, bitrate, folder, name}`: changes the settings given
- `recorder_start`: accepts the same settings; returns once recording, or fails with the reason
- `recorder_stop`: returns once the movie is finished, with its path

    Tools/mcp-call.py "build/Simple Client.app/Contents/MacOS/simple-recorder-mcp" recorder_status

Building
--------

Requires Xcode 16 or later. The apps run on macOS 13 or later, on Apple silicon and Intel.

The Syphon framework is a submodule, so clone with `--recursive` or fetch it afterwards:

    git submodule update --init

`Scripts/bundle.sh` builds both applications for release into `build/`, with the MCP server inside Simple Client, and signs them (`INSTALL=1` also copies them to `/Applications`). It signs with your Developer ID or Apple Development identity if you have one, so that macOS remembers the Local Network permission the applications are given; otherwise it asks again after each build.

To work on them, open `Simple.xcworkspace`, or build from the command line:

    xcodebuild -workspace Simple.xcworkspace -scheme "Simple Client" -configuration Release -destination 'generic/platform=macOS' build
    xcodebuild -workspace Simple.xcworkspace -scheme "Simple Server" -configuration Release -destination 'generic/platform=macOS' build

Tests
-----

The recorder's core is in `Recorder/`: Objective-C which does not depend on Syphon, compiled into Simple Client and, by `Package.swift`, into a library with tests:

    swift test

They cover which frames a maximum frame rate keeps, OSC messages and the UDP receiver, the OSCQuery server (which is eMotion's, unchanged), movies written from synthetic textures and read back (size, frame count, orientation, transparency, bitrate), and the recorder's parameters and states.

Checking without looking at the screen
--------------------------------------

`Tools/build.sh` builds command line tools into `build/tools`:

- `syphon-probe` lists the Syphon servers which are running, or saves a frame from one of them as a PNG and prints its size and frame rate
- `view-test` saves what `SimpleImageView` draws for a frame from Simple Server
- `gl-server` is a minimal OpenGL Syphon server, to compare with frames from Metal
- `settings-test` drives the controls of the settings popover and the toolbar's record item, and saves a picture of the popover
- `movie-info` prints the size, duration, frame count, frame rate and codec of movies, and can save a frame

`Tools/osc-send.py` sends an OSC message, and `Tools/mcp-call.py` calls a tool of an MCP server.
