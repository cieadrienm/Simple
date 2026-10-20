Simple Recorder
===============

Simple Recorder records several [Syphon](https://github.com/Syphon/Syphon-Framework) and [NDI](https://ndi.video) sources at once: each to its own movie, all assembled in one movie (side by side, stacked, as a mosaic), or both, on one clock. It can be driven from its window, by OSC (described by OSCQuery) and by MCP.

It grew out of Syphon's Simple Client. **Simple Server**, its companion, is still here: it publishes an animated test pattern (a pulsing background, a bar which sweeps across the frame and a marker in the top left corner), and `-ServerName A` gives it a name, so that several can run and be told apart.

The window
----------

- **Sources**, on the left: the Syphon servers which are running, and the NDI sources found on the network, tagged "NDI". Tick one to record it; drag the ticked ones to order them. A source which goes away keeps its place, dimmed, and takes it again when it is back — also when its application was killed and relaunched. Up to eight. Only ticked sources are connected to. A note sign marks the sources which have sound.
- **The picture**, in the middle: the sources assembled, live, as they are (or would be) recorded, each with its title over its part — the titles are not recorded. Under it, the four layouts and the picture's size. With *Separate* it is still shown: it is how the sources are watched. It follows every frame of its source, at the display's rate; in performance mode, while recording, it is shown ten times a second and "Display limited" says so.
- **Settings**, on the right: the codec, frame rate, bitrate and sound (*Sound*: *None*, *Computer* for the sound played on this Mac, or one of the sources chosen) of the movies; the size of the assembled picture and the gap between its sources; the folder and the name; and *Performance mode* (under "Display"): while recording, the picture is shown ten times a second instead of at every frame, to leave the GPU to the encoders on a loaded machine. It applies at once, also during a recording, and changes nothing in the movies; when not recording the picture is as smooth as ever.
- **The take**, on top: the record button (⌘R), which stays pressed and shows a stop square while recording, whatever started the recording; the time; frames written and dropped; and what a recording writes: *Separate*, *Assembled* or *Both*.
- **The state**, at the bottom: the OSC and OSCQuery ports, whether NDI is available ("NDI on" or "NDI off"), the space left, how many movies a recording writes, why the last recording ended if it failed, and the version ("v0.9", or "dev" when not run from the app; clicking it opens the About window).
- **Help** (`Help ▸ Simple Recorder Help`, ⌘?): a searchable HTML guide in a window of its own (`Resources/Help/index.html`).

Recording
---------

A recording writes, as chosen before it starts:

- **Separate**: each ticked source to its own `.mov`, at its own size;
- **Assembled**: one `.mov` of all the sources in one picture;
- **Both**: all of these.

The movies of a recording share its clock: each begins when its first frame arrives, so that they line up when laid one above the other in an editor.

The sources are assembled in their order, on black (transparent with ProRes 4444, which also keeps each source's own transparency):

| Layout | The picture's automatic size |
|---|---|
| **Row** (side by side) | every source at the height of the tallest; the widths added |
| **Column** (stacked) | every source at the width of the widest; the heights added |
| **Grid** (mosaic) | as many columns as the square root of the number of sources, rounded up; cells the size of the largest source, each source fitted in its cell |
| **Focus** | the first source at its own size; the others share its height in a column on its right |

With a size given, the whole picture is fitted into it, without distortion. One source alone is itself, whatever the layout. The picture of a recording is decided when it starts, from the sources as they are then, and does not change: a source which is away leaves its place black (as large as it was last seen, or as 1920 × 1080 if it never was), and one whose size changes is fitted in its place. A picture is written each time the first source which is delivering frames delivers one, with the latest frame of each of the others. A picture of more than 16384 pixels on a side cannot be written: the recording does not start, and says so — give the assembled picture a size.

- **Codec**: H.264, HEVC, ProRes 422 or ProRes 4444 (which keeps transparency).
- **Frame rate**: every frame of the sources, or a maximum. Above the maximum, frames in excess are discarded and those kept are evenly timed.
- **Bitrate**: megabits per second for H.264 and HEVC, or automatic. ProRes has none to choose.
- **Names**: `<name>.mov` for the assembled movie, `<name> — <source>.mov` for each source's; a single source recorded alone, not assembled, is `<name>.mov`. An empty name is `Simple Recorder` and the date. An existing movie is never overwritten: a number is added, the same for every movie of the recording.

Frames are encoded on the GPU, away from the main thread. If an encoder cannot keep up frames are dropped, and counted, rather than delaying anything. Quitting, closing the window or `kill` while recording finishes the movies first. If writing one movie fails (a full disk, for instance) the others go on, the reason stays in the window for as long as the recording does and until the next one, and what was written is kept. The sources cannot be changed while recording.

NDI sources
-----------

NDI sources are listed beside the Syphon servers, tagged "NDI", and are recorded in the same way: a movie each, assembled, or both. NDI pictures are received as BGRA at full quality and are not flipped; a source without alpha is recorded opaque. Their sound is recorded too (see Sound, below).

NDI needs its library, `libndi.dylib`, which Simple Recorder loads at run time. `Scripts/bundle.sh` copies it into the app when the NDI SDK is installed (`/Library/NDI SDK for Apple`); otherwise the app looks for the NDI runtime (`$NDI_RUNTIME_DIR_V6`, then `/usr/local/lib`), then for the SDK's own copy (`/Library/NDI SDK for Apple/lib/macOS/libndi.dylib`), and only when none is found runs with "NDI off": the Syphon sources work as before and nothing is reported as an error. `SIMPLE_NDI_LIBRARY` in the environment chooses a library (an empty value counts as unset; a path to nothing runs with NDI off). If a Syphon server and an NDI source have the same title, the Syphon one is taken. Finding NDI sources on the network needs the Local Network permission, which macOS asks the app for.

NDI® is a registered trademark of Vizrt NDI AB.

Sound
-----

NDI sources which send sound are recorded with it in their own movies, and *Sound* (in the window's "Movie" settings, or `/sound`; *None* by default) chooses between:

- **A source**: the assembled movie takes that source's sound. A note sign in the list of sources marks those which have sound.
- **Computer** (`/sound computer`): records the sound being played by all applications on this Mac (not the microphone). With *Assembled* or *Both* it goes into the assembled movie (while NDI sources keep their own sound in their separate movies); with *Separate* it goes into each Syphon source's movie (while NDI sources keep their own sound). Capturing the Mac's sound uses a Core Audio process tap (macOS 14.2+), for which macOS asks the System Audio Recording permission.

A movie which receives no sound has no sound track, exactly as before.

- **Format**: 48 kHz, two channels: the first two of the source, a single channel being copied to both. AAC at 256 kbit/s with H.264 and HEVC, linear PCM at 24 bits with ProRes. Sound at another rate is converted.
- **In step with the pictures**: like frames, sound is placed by its arrival. Measured on recordings of the SDK's own sender, sound is ahead of its picture by less than a frame (about 10 ms for a 60 fps source, 25 ms for a 30 fps one, most of which is the wait for the next picture), and stays so over ten minutes. The track is one unbroken stream: where sound is missing (it starts late, the sender was away) there is silence. A source whose clock drifts from this Mac's is brought back by corrections of about 20 ms (a short silence, or as much sound left out), a few times an hour at most.
- **Never delaying the pictures**: if an encoder cannot keep up, sound is left out and counted (`/status/sound/leftout`), and the pictures are written as usual.
- **Limits**: two channels. The sound of the source chosen stays chosen when its source is unticked, and is decided when a recording starts.

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
| `/output` | string | read, write | `separate`, `assembled`, `both`: what a recording writes |
| `/layout` | string | read, write | `row`, `column`, `grid`, `focus`: how the sources are assembled |
| `/gap` | int | read, write | Pixels between the sources in the assembled picture, up to 1000 |
| `/width`, `/height` | int | read, write | The size the assembled picture is fitted into; 0 for the size the sources need |
| `/sound` | string | read, write | What sound is recorded: `computer` for the sound played on this Mac, the title (or part of it) of one of the sources chosen for the assembled movie, or empty for none (the default). OSCQuery lists the titles and `computer` as its `RANGE`. |
| `/performance` | int | read, write | 1: while recording, the picture in the window is drawn ten times a second, and composed only that often when no assembled movie needs it at every frame, to leave the GPU to the movies; 0 (the default): every frame. Any number but 0 counts as 1. It applies at once. |
| `/status/version` | string | read | The version of Simple Recorder, as `0.9`; `dev` when it is not run from its application |
| `/status/state` | string | read | `idle`, `recording`, or `finishing` while the movies are completed |
| `/status/elapsed` | float | read | Seconds recorded |
| `/status/dropped` | int | read | Frames lost in all the movies because an encoder could not keep up |
| `/status/error` | string | read | The last error: a message which was refused, a recording which could not start or failed. Empty when a recording starts. |
| `/status/failure` | string | read | Why the last recording ended, if it failed or had nothing to write. Empty otherwise. |
| `/status/ndi` | int | read | 1 if NDI's library is loaded, 0 if NDI is off |
| `/status/ndi/sources` | string | read | The titles of the NDI sources available, one per line (those of `/source`'s `RANGE` which are not in it are Syphon servers) |
| `/status/source/N/kind` | string | read | `syphon` or `ndi`: what the source in place N is, learned when it connects; empty if it never has |
| `/status/source/N/online` | int | read | 1 if the source in place N is delivering frames |
| `/status/source/N/width`, `/height`, `/fps` | int, int, float | read | What it delivers |
| `/status/source/N/file`, `/frames`, `/dropped` | string, int, int | read | Its movie |
| `/status/source/N/sound` | int | read | 1 if the source in place N is sending sound |
| `/status/source/N/soundwritten` | float | read | Seconds of sound in its movie |
| `/status/sound/written` | float | read | Seconds of sound in the assembled movie |
| `/status/sound/leftout` | float | read | Seconds of sound left out in all the movies because an encoder could not keep up |
| `/status/assembled/width`, `/height` | int | read | The size of the assembled picture as it is now, or of the recording in progress |
| `/status/assembled/file`, `/frames`, `/dropped` | string, int, int | read | The assembled movie |
| `/status/file`, `/status/frames` | string, int | read | The assembled movie or, if there is none, the first source's |

A source's own movie is always the size of the source: `/width` and `/height` concern the assembled picture only. `/output`, `/layout`, `/gap`, `/width`, `/height` and `/sound` can be set while recording; they apply to the next recording. `/performance` can be set while recording too, and applies at once.

OSC has no passwords: any machine which can reach Simple Recorder's port can start and stop recordings and change where they are written. Use it on a network you trust.

Numbers are accepted as int or float. Settings are saved, and apply to the next recording. A message which cannot be applied (a wrong argument, an address which does not exist, a source changed while recording) is reported in `/status/error` and, for a few seconds, beside the time in the window.

    Tools/osc-send.py 9230 /source/1 "main view - eMotion"
    Tools/osc-send.py 9230 /source/2 "depthMap"
    Tools/osc-send.py 9230 /output both
    Tools/osc-send.py 9230 /layout focus
    Tools/osc-send.py 9230 /record 1
    curl 'localhost:9231/status/state?VALUE'

MCP
---

`simple-recorder-mcp` is inside the app (`Contents/MacOS`). It is a stdio MCP server which reads the recorder through OSCQuery and writes with OSC, so the app must be running. `.mcp.json` declares it for Claude Code, from `build/Simple Recorder.app`.

- `recorder_status`: the `version` of the app, the sources chosen, each with its `kind` (`syphon` or `ndi`) and what it delivers and writes (`sound`: whether it sends sound; `soundWritten`: seconds of sound in its movie), `ndi` (whether NDI's library is loaded), the sources available as a list of `{title, kind}` (a list of plain titles before NDI: its shape changed), settings (`sound`: `computer`, the source whose sound the assembled movie takes, or empty; `performance`: whether the window's picture is held back while recording), the assembled picture and its movie (`assembled`, with `soundWritten`, seconds of sound in it), `soundLeftOut`, state, errors
- `recorder_configure {sources, source, codec, fps, bitrate, folder, name, output, layout, gap, width, height, sound, performance}`: changes what is given; `sources` is a list of titles, in order, of Syphon servers or NDI sources; `sound` is `"computer"` for the sound played on this Mac, the title (or part of it) of the source among them whose sound the assembled movie takes, or empty for none; `performance` (true or false) holds the window's picture back to ten a second while recording, and applies at once
- `recorder_start`: accepts the same; returns once recording, or fails with the reason
- `recorder_stop`: returns once the movies are finished, with their paths

    Tools/mcp-call.py "build/Simple Recorder.app/Contents/MacOS/simple-recorder-mcp" recorder_status

Building
--------

Requires Xcode 16 or later. The apps run on macOS 14 or later, on Apple silicon and Intel.

    Scripts/bundle.sh

builds `build/Simple Recorder.app` and `build/Simple Server.app` for release and signs them (`INSTALL=1` also copies them to `/Applications`). It signs with your Developer ID or Apple Development identity if you have one, so that macOS remembers the Local Network permission the app is given; otherwise it asks again after each build.

Versions
--------

The version is `VERSION` at the top of `Scripts/bundle.sh`, and only there; the script stamps it, with a build number which counts the commits, into the app's `Info.plist` (`Resources/Info.plist` keeps the placeholders `@VERSION@` and `@BUILD@`). The About panel, the window's bottom bar, `/status/version` and the MCP's `recorder_status` show it; outside the app (`swift run`, the tests) it is `dev`. What changed is in `CHANGELOG.md`, and each release is tagged `vX.Y.Z` in git.

The app's icon is drawn by `swift Scripts/make-icon.swift`, which writes `Resources/icon.icns`.

Simple Recorder is a SwiftPM package: the window in `App/` (SwiftUI), the recording core in `Recorder/` (Objective-C, independent of Syphon), the MCP server in `MCP/`. Syphon's framework is a submodule, given to SwiftPM as an xcframework which `Scripts/syphon.sh` builds — run it once before `swift build` (`Scripts/bundle.sh` does). Simple Server is built from `Simple.xcworkspace`.

Tests
-----

    Scripts/syphon.sh && swift test

They cover which frames a maximum frame rate keeps, OSC messages and the UDP receiver, the OSCQuery server (which is eMotion's, unchanged), movies written from synthetic textures and read back (size, frame count, orientation, transparency, bitrate, a disk which fills up), a recording of several sources (names, one clock, the assembled movie), the layouts, the sources composed into one picture and read back, the sources chosen and their states over OSC, Syphon servers as sources, NDI sources (tested against a sender made with NDI's own library, and skipped when the library is absent), sound (a tone written to a movie and read back, its frequency, format and duration; sound and picture in step, measured against the SDK's own sender; silence where sound is missing; sound left out rather than delaying pictures), the window's model, and the window itself, which is drawn off screen to `build/views/*.png` in its main states.

Checking without looking at the screen
--------------------------------------

`Tools/build.sh` builds command line tools into `build/tools`:

- `syphon-probe` lists the Syphon servers which are running, or saves a frame from one of them as a PNG and prints its size and frame rate
- `gl-server` is a minimal OpenGL Syphon server, to compare with frames from Metal
- `view-test` saves what Simple Server's view draws for a frame
- `movie-info` prints the size, duration, frame count, frame rate and codec of movies and when their picture starts, and can save a frame. When a movie has a sound track, a second line gives its codec, sample rate, channels, duration and where sound which is not silence begins. `movie-info --sync <movie> [--region x y w h]` finds the flashes and clicks of a movie made from `ndi-send --tone` and prints, for each second, how far the picture is from the sound (picture minus click, in milliseconds), then the minimum, maximum and mean; `--region` (fractions of the picture) restricts the flashes to one source's place in an assembled picture

- `ndi-send <name> [width height fps] [--bgrx] [--tone [--rate hz] [--channels 1|2|4]]` is an NDI sender of Simple Server's test pattern (1280 × 720 at 30 by default), to try NDI sources; `--bgrx` sends frames without alpha. `--tone` sends sound too (48 kHz and two channels unless told otherwise): a sine on each channel (440, 880, 1320 and 1760 Hz, at −12 dB) and, each second, a 5 ms click at full scale on every channel at the moment of one picture which is white all over, so that `movie-info --sync` can measure the step between sound and picture. It ends on SIGTERM or Ctrl-C.

`Tools/osc-send.py` sends an OSC message, and `Tools/mcp-call.py` calls a tool of an MCP server.
