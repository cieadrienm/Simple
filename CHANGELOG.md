Changelog
=========

The version is `VERSION` in `Scripts/bundle.sh`; each release is tagged `vX.Y` in git.

0.9.1 — 2026-10-24
------------------

- Simple Recorder becomes SimpleRecorder, like SimpleAudio and SimpleText: the app (`SimpleRecorder.app`), its menus, About window, Help and status bar, the default name of the movies (`SimpleRecorder <date>`), the NDI receiver and the computer sound tap. The bundle identifier stays `net.am-cb.simple-recorder`, so settings and permissions are kept.
- Licensed under the GNU GPL, version 3 or later, with an additional permission for NDI's library; Syphon's original code keeps its BSD licence.

0.9 — 2026-10-20
----------------

The first numbered version.

- Several Syphon and NDI sources recorded at once, on one clock: each to its own movie, all assembled in one movie (row, column, grid, focus), or both.
- NDI sound, in each source's movie and, for the source chosen, in the assembled movie.
- Computer sound (`Computer` in *Sound*, or `/sound computer`): records the sound being played on the Mac (in the assembled movie when *Assembled* or *Both* is chosen, or in each Syphon source's movie when *Separate* is chosen), through a Core Audio process tap without Screen Recording permission.
- Control from the window, by OSC (described by OSCQuery) and by MCP.
- The picture shown follows every frame of its source, at the display's rate.
- Performance mode: while recording, the picture is shown ten times a second, to leave the GPU to the movies.
- About window (`Simple Recorder ▸ About Simple Recorder`, or click the version in the bottom bar) and searchable HTML Help guide (`Help ▸ Simple Recorder Help`, ⌘?).
- A new icon.
- The recorder takes its pixel buffers from a pool of its own rather than the encoder's, after two crashes of the test process there.
