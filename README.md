Simple Recorder
===============

Simple Recorder records several [Syphon](https://github.com/Syphon/Syphon-Framework) sources at once, each to its own movie, all on one clock. It can be driven from its window, by OSC (described by OSCQuery) and by MCP.

It grew out of Syphon's Simple Client. **Simple Server**, its companion, is still here: it publishes an animated test pattern (a pulsing background, a bar which sweeps across the frame and a marker in the top left corner), and `-ServerName A` gives it a name, so that several can run and be told apart.

The window
----------

- **Sources**, on the left: the Syphon servers which are running. Tick one to record it; drag the ticked ones to order them. A source which goes away keeps its place, dimmed, and takes it again when it is back — also when its application was killed and relaunched. Up to eight. Only ticked sources are connected to.
- **What they deliver**, in the middle, as it arrives.
- **Settings**, on the right: the codec, frame rate and bitrate of the movies; the folder and the name.
- **The take**, on top: the record button (⌘R), which stays pressed and shows a stop square while recording, whatever started the recording; the time; frames written and dropped.
- **The state**, at the bottom: the OSC and OSCQuery ports, the space left, how many movies a recording writes, and why the last recording ended if it failed.

Recording
---------

Each ticked source is written to its own `.mov`, at its own size. The movies of a recording share its clock: each begins when its source's first frame arrives, so that they line up when laid one above the other in an editor.

- **Codec**: H.264, HEVC, ProRes 422 or ProRes 4444 (which keeps transparency).
- **Frame rate**: every frame of the sources, or a maximum. Above the maximum, frames in excess are discarded and those kept are evenly timed.
- **Bitrate**: megabits per second for H.264 and HEVC, or automatic. ProRes has none to choose.
- **Names**: `<name>.mov` for one source, `<name> — <source>.mov` for several; an empty name is `Simple Recorder` and the date. An existing movie is never overwritten: a number is added, the same for every movie of the recording.

Frames are encoded on the GPU, away from the main thread. If an encoder cannot keep up frames are dropped, and counted, rather than delaying anything. Quitting, closing the window or `kill` while recording finishes the movies first. If writing one movie fails (a full disk, for instance) the others go on, the reason stays in the window for as long as the recording does and until the next one, and what was written is kept. The sources cannot be changed while recording.

OSC and OSCQuery
----------------

Simple Recorder listens for OSC on UDP port **9230** and describes its parameters to OSCQuery clients on HTTP port **9231**, announced by Bonjour (`_oscjson._tcp`). If a port is taken the next free one is used; the window's bottom bar shows the ports in use. `SIMPLE_OSC_PORT` and `SIMPLE_OSCQUERY_PORT` in the environment choose other ports, to run a second copy.

| Address | Type | | |
|---|---|---|---|
| `/source/1` … `/source/8` | string | read, write | The source in that place: its title as in the window, or part of it. Empty for none: the sources after it move up. OSCQuery lists the sources available as its `RANGE`. |
| `/source` | string | read, write | The same as `/source/1` |
| `/record` | int | read, write | 1 starts recording, 0 stops and finishes the movies |
| `/record/toggle` | – | write | Starts, or stops |
| `/codec` | string | read, write | `h264`, `hevc`, `prores422`, `prores4444` |
| `/fps` | float | read, write | 0 for every frame of the sources |
| `/bitrate` | float | read, write | Megabits per second, 0 for automatic |
| `/folder`, `/name` | string | read, write | An empty name is the app's name and the date |
| `/status/state` | string | read | `idle`, `recording`, or `finishing` while the movies are completed |
| `/status/elapsed` | float | read | Seconds recorded |
| `/status/dropped` | int | read | Frames lost in all the movies because an encoder could not keep up |
| `/status/error` | string | read | The last error: a message which was refused, a recording which could not start or failed. Empty when a recording starts. |
| `/status/failure` | string | read | Why the last recording ended, if it failed or had nothing to write. Empty otherwise. |
| `/status/source/N/online` | int | read | 1 if the source in place N is delivering frames |
| `/status/source/N/width`, `/height`, `/fps` | int, int, float | read | What it delivers |
| `/status/source/N/file`, `/frames`, `/dropped` | string, int, int | read | Its movie |
| `/status/file`, `/status/frames` | string, int | read | The first source's movie |

`/width` and `/height` exist and are saved, for the assembled movie to come; a source's own movie is always the size of the source.

OSC has no passwords: any machine which can reach Simple Recorder's port can start and stop recordings and change where they are written. Use it on a network you trust.

Numbers are accepted as int or float. Settings are saved, and apply to the next recording. A message which cannot be applied (a wrong argument, an address which does not exist, a source changed while recording) is reported in `/status/error` and, for a few seconds, beside the time in the window.

    Tools/osc-send.py 9230 /source/1 "main view - eMotion"
    Tools/osc-send.py 9230 /source/2 "depthMap"
    Tools/osc-send.py 9230 /record 1
    curl 'localhost:9231/status/state?VALUE'

MCP
---

`simple-recorder-mcp` is inside the app (`Contents/MacOS`). It is a stdio MCP server which reads the recorder through OSCQuery and writes with OSC, so the app must be running. `.mcp.json` declares it for Claude Code, from `build/Simple Recorder.app`.

- `recorder_status`: the sources chosen and what each delivers and writes, the sources available, settings, state, errors
- `recorder_configure {sources, source, codec, fps, bitrate, folder, name}`: changes what is given; `sources` is a list of titles, in order
- `recorder_start`: accepts the same; returns once recording, or fails with the reason
- `recorder_stop`: returns once the movies are finished, with their paths

    Tools/mcp-call.py "build/Simple Recorder.app/Contents/MacOS/simple-recorder-mcp" recorder_status

Building
--------

Requires Xcode 16 or later. The apps run on macOS 14 or later, on Apple silicon and Intel.

    Scripts/bundle.sh

builds `build/Simple Recorder.app` and `build/Simple Server.app` for release and signs them (`INSTALL=1` also copies them to `/Applications`). It signs with your Developer ID or Apple Development identity if you have one, so that macOS remembers the Local Network permission the app is given; otherwise it asks again after each build.

Simple Recorder is a SwiftPM package: the window in `App/` (SwiftUI), the recording core in `Recorder/` (Objective-C, independent of Syphon), the MCP server in `MCP/`. Syphon's framework is a submodule, given to SwiftPM as an xcframework which `Scripts/syphon.sh` builds — run it once before `swift build` (`Scripts/bundle.sh` does). Simple Server is built from `Simple.xcworkspace`.

Tests
-----

    Scripts/syphon.sh && swift test

They cover which frames a maximum frame rate keeps, OSC messages and the UDP receiver, the OSCQuery server (which is eMotion's, unchanged), movies written from synthetic textures and read back (size, frame count, orientation, transparency, bitrate, a disk which fills up), a recording of several sources (names, one clock), the sources chosen and their states over OSC, Syphon servers as sources, the window's model, and the window itself, which is drawn off screen to `build/views/*.png` in its main states.

Checking without looking at the screen
--------------------------------------

`Tools/build.sh` builds command line tools into `build/tools`:

- `syphon-probe` lists the Syphon servers which are running, or saves a frame from one of them as a PNG and prints its size and frame rate
- `gl-server` is a minimal OpenGL Syphon server, to compare with frames from Metal
- `view-test` saves what Simple Server's view draws for a frame
- `movie-info` prints the size, duration, frame count, frame rate and codec of movies and when their picture starts, and can save a frame

`Tools/osc-send.py` sends an OSC message, and `Tools/mcp-call.py` calls a tool of an MCP server.
