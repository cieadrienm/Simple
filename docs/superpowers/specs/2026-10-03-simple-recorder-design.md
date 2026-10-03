# Simple Recorder — design

Date: 2026-10-03. Direction approved by Adrien in conversation, after a mock-up of the window
("Oui ça me convient, écris la spec").

## Goal

Simple Client becomes **Simple Recorder**: one window, as plain as OSCScore's, which records several
video sources at once — Syphon servers and NDI sources — either to one movie per source, to a single
movie in which they are assembled (side by side, stacked, mosaic), or both. Everything stays reachable
by OSC (described by OSCQuery) and by MCP.

It builds on what exists: the recording core (`Recorder/`), its tests, the OSC and OSCQuery surface.

## What Adrien decided

- **Output chosen for each take**: separate movies, an assembled movie, or both at once.
- **Ready-made layouts only**: no free placement. The order of the sources decides who goes where.
- **NDI sound is recorded.** Syphon has none.
- The app is renamed **Simple Recorder**.
- The window in three zones shown in the mock-up: sources on the left, the picture which will be
  recorded in the middle, settings on the right, the take (record button, time, output) on top, the
  state at the bottom.

## Decisions made for him (recommended in conversation, not objected to)

- **The window is written in SwiftUI**, as OSCScore's is; the recording core stays Objective-C. This
  reverses D10 (no Swift in the app): the old window was a nib and forty lines of glue, this one is an
  interface.
- **The app is built with SwiftPM and `Scripts/bundle.sh`**, as OSCScore is, rather than by an Xcode
  target edited by hand. Syphon is given to SwiftPM as an xcframework built from the submodule by a
  script. Simple Server keeps its Xcode project. To be proved by the first task of the first plan; the
  fallback is an Xcode target.
- **macOS 14 minimum** (13 today), as OSCScore.
- **NDI through its SDK's library, loaded when the app starts** (`libndi.dylib`, NDI 6, universal,
  already in `/Library/NDI SDK for Apple`). `bundle.sh` copies it into the app; without it the app runs
  and says "NDI off". The SDK's headers are MIT-licensed and are added to the repository; the library
  is not.
- **Identifier `net.am-cb.simple-recorder`.** The recorder's settings are copied once from
  `net.am-cb.simple-client`. macOS will ask for the Local Network permission again.
- **The repository keeps its name** (`Simple`): renaming it is Adrien's to ask for.

## The window

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ (●)  0:13:45   49 176 frames · 0 dropped          [Separate|Assembled|Both]  │
├───────────────┬──────────────────────────────────────────┬───────────────────┤
│ SOURCES       │                                          │ MOVIE             │
│ ☑ main view   │   ┌──────────────────────┬───────────┐   │  Codec, Frame     │
│   eMotion …   │   │                      │ depthMap  │   │  rate, Bitrate    │
│ ☑ depthMap    │   │      main view       ├───────────┤   │ ASSEMBLED         │
│ ☑ Caméra  ♪   │   │                      │ Caméra    │   │  Size, Gap, Sound │
│ AVAILABLE     │   └──────────────────────┴───────────┘   │ FILES             │
│ ☐ Map         │   [▥][▤][▦][◧]               2880 × 1080 │  Folder, Name     │
├───────────────┴──────────────────────────────────────────┴───────────────────┤
│ OSC :9230   OSCQuery :9231   NDI on                 412 GB free · 4 movies   │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Sources (left).** Syphon and NDI in one list, found automatically. Ticking a source adds it to the
  take; unticking removes it. Ticked sources come first, in an order changed by dragging; that order is
  their place in the assembled picture. Each row: title, application or "NDI", size and rate, a note
  sign when it carries sound. A ticked source which has gone stays in the list, dimmed, and takes its
  place again when it comes back (the rule of D23, for every source). At most eight are ticked.
  While a take is being recorded the ticked sources and their order cannot be changed.
  Only ticked sources are connected to: the app does not attach itself to every server it sees.
- **Picture (middle).** The assembled picture, live, exactly as it is recorded, with each source's
  title over its part (the titles are not recorded). In "Separate" it is still shown, as a monitor.
  Under it, the four layouts and the size of the assembled movie. With no source ticked: an invitation
  to tick one.
- **Settings (right).** *Movie*: codec, frame rate, bitrate — one set for every movie of the take.
  *Assembled*: size (automatic, or a size the picture is fitted into), gap between sources, which NDI
  source gives the sound. *Files*: folder, name.
- **Take (top).** The record button, which stays pressed and shows a stop square while recording
  (D32); the time, large; frames written and dropped; the output: Separate, Assembled, Both.
- **State (bottom).** OSC and OSCQuery ports, whether NDI is available, free space on the folder's
  disk and how many movies the take writes. Errors appear here and, for a few seconds, in place of the
  time's caption (D34 carries over: an error must not depend on a part of the window being visible).
- Dark only, with OSCScore's palette and its small section titles and fixed-width figures.

## Sources

A source is something which delivers pictures, and perhaps sound:

- **Syphon**: as today (`SyphonMetalClient`), first row at the bottom.
- **NDI**: found with the SDK's finder; received as BGRA, copied to a Metal texture, first row at the
  top; its sound as floating-point samples.

A source is known by its kind and its title (`name - application` for Syphon, the NDI name for NDI).
Two sources with the same title: the first is taken, as today.

## What a take writes

- **Separate**: one movie per ticked source, at that source's size, with its sound if it is NDI.
- **Assembled**: one movie of the assembled picture, with the sound of the NDI source chosen in
  *Sound* (none by default).
- **Both**: all of them.

All the movies of a take share one clock: time zero is the moment the take started, not each movie's
first frame, so that separate movies line up when laid one above the other in an editor. They share
the codec, frame rate and bitrate settings; the size setting concerns the assembled movie only.

Names, in the folder: `<name>.mov` for the assembled movie, `<name> — <source title>.mov` for each
source. A take of one source, not assembled, is `<name>.mov` alone, as Simple Client's were. An empty name is `Simple Recorder yyyy-MM-dd HH.mm.ss`. Nothing is ever overwritten: if any of
the take's names exists, the same number is added to all of them.

The assembled movie's frames are produced when the first ticked source which is delivering frames
delivers one (within the frame rate setting), using the latest picture of each other source. A source
which is away leaves its place black; the picture's size is decided when the take starts and does not
change (a source never seen counts as 1920 × 1080).

Sound is recorded as AAC in H.264 and HEVC movies and as linear PCM in ProRes movies, the first two
channels of the source, on the take's clock.

What already holds stays: a movie which has frames is never deleted (D21), an encoder which cannot keep
up drops frames and counts them (D19), a take cannot start while the previous one is being finished
(D27), quitting finishes the movies (D26).

## Layouts

For *n* sources in order, with a gap between them, on black (transparent in ProRes 4444):

| Layout | Automatic size |
|---|---|
| **Row** (side by side) | every source at the height of the tallest; widths added |
| **Column** (stacked) | every source at the width of the widest; heights added |
| **Grid** (mosaic) | ⌈√n⌉ columns; every cell the size of the largest source; each source fitted in its cell |
| **Focus** | the first source at its own size; the others share its height in a column on its right |

With a size given, the whole picture is fitted into it without distortion. Dimensions are even. With
one source, every layout is that source alone.

## Parameters

One table, as today (D12). Unchanged: `/record`, `/record/toggle`, `/codec`, `/fps`, `/bitrate`,
`/folder`, `/name`, `/status/state`, `/status/elapsed`, `/status/error`, `/status/failure`.

| Address | Type | Access | Meaning |
|---|---|---|---|
| `/source/1` … `/source/8` | s | rw | the title of the source in that place, empty for none. `RANGE.VALS` lists the sources available. Setting matches the exact title, then a part of it. The places close up: there is no hole in the list |
| `/source` | s | rw | the same as `/source/1`, so that what drives Simple Client today keeps working |
| `/output` | s | rw | `separate`, `assembled`, `both` |
| `/layout` | s | rw | `row`, `column`, `grid`, `focus` |
| `/gap` | i | rw | pixels between sources |
| `/width`, `/height` | i | rw | size of the assembled movie, 0 for automatic |
| `/sound` | s | rw | title of the NDI source whose sound goes in the assembled movie, empty for none |
| `/status/source/N/online` | i | r | 1 if the source in place N is delivering frames |
| `/status/source/N/width`, `/height`, `/fps` | i, i, f | r | what it delivers |
| `/status/source/N/file`, `/frames`, `/dropped` | s, i, i | r | its movie, in Separate and Both |
| `/status/assembled/width`, `/height` | i, i | r | the size the assembled picture has now |
| `/status/assembled/file`, `/frames`, `/dropped` | s, i, i | r | the assembled movie |
| `/status/frames`, `/status/dropped` | i | r | frames of the assembled movie (of the first source's in Separate); frames dropped in all the movies |
| `/status/file` | s | r | the assembled movie, or the first source's in Separate |
| `/status/ndi` | i | r | 1 if NDI is available |

`/status/source/width`, `/height` and `/fps` (without a place) go: they are `/status/source/1/…`.

## MCP

The same four tools. `recorder_configure` and `recorder_start` also take `sources` (titles, in order),
`output`, `layout`, `gap` and `sound`. `recorder_status` lists the sources available with their kind,
the places, and the movies of the take. The tool finds the app by its new name.

## Structure

```
Recorder/              Objective-C, no Syphon: what exists, plus
  FrameSource            what a source is (protocol): title, kind, frames, sound
  NDISource, NDIFinder   NDI through the library loaded at run time
  Layout                 the four layouts: sizes and places (pure)
  Compositor             the sources' latest pictures → one texture (Metal)
  Take                   the movies of one recording, their clock, their names
  MovieRecorder          + a sound track, + a clock given from outside
  RecorderController     + places, output, layout; the parameter table
ThirdParty/NDI/include  the SDK's headers
App/                   Swift: SwiftUI window, SyphonSource, the model over RecorderController
MCP/, Tools/, Tests/   as today, extended
Simple Server/         unchanged
```

`Simple Client/` and `Common/SimpleImageView` leave the recorder (Simple Server keeps the view).

## In four parts

Each is a plan of its own, and leaves an app which works:

1. **Simple Recorder with several Syphon sources, separate movies.** The rename, the SwiftPM build,
   the SwiftUI window (sources, a monitor of the ticked sources, settings, state), the places in OSC
   and MCP, one clock for the take.
2. **The assembled movie.** Layouts, compositor, the picture in the middle as it is recorded, the
   output choice, `/layout`, `/gap`, `/width`, `/height`.
3. **NDI pictures.** The library, the finder, NDI sources in the list.
4. **NDI sound.** A sound track in the movies, `/sound`.

## Errors

As today: nothing is silent. A source ticked but away when the take starts is not an error (its movie
starts when it arrives; its place is black); a take with no source ticked, or with none delivering
frames when it stops, is. NDI missing is a state, shown, not an error.

## Tests

`swift test` for everything in `Recorder/`: layouts (sizes and places for one to eight sources, odd
sizes, a size given), the compositor (pictures read back: each source in its place, the right way up
for a Syphon and for an NDI source), a take (names, the same number for all, one clock: two movies
whose first frames arrive apart are that far apart), sound (a tone written and read back, in step with
the picture), the places (OSC, closing up, the source which comes back), with sources which are fakes.
NDI itself is tested against the SDK's own sender when the library is there, and skipped when not.

The window: a harness which drives the model and renders the views off screen, as `settings-test`
does today. End to end on the signed app with Simple Server (several copies, on other ports) and an
NDI sender, by OSC and by MCP, the movies read back with `movie-info`.

## Not in this design

Free placement, per-source codec or size, Syphon output of the assembled picture, more than two
channels of sound, sound from an audio device, a preview of sources which are not ticked.
