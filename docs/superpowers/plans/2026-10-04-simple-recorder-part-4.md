# Simple Recorder, part 4: NDI sound — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sound of an NDI source is recorded: in that source's own movie, and — for the one source chosen — in the assembled movie, in step with the pictures.

**Architecture:** A source may deliver sound beside its frames: `FrameSource` gains a sound handler, and `NDISource` gives each NDI audio frame as a `SourceSound` (two channels of floating-point samples). `MovieRecorder` gains a sound track: sound is placed on the movie's clock by a `SoundTimeline`, which keeps the track one unbroken stream of samples (silence added, or samples left out, when the source's clock and ours part), and is written as AAC or linear PCM by the same `AVAssetWriter`. `Take` routes each source's sound to its movie and one source's to the assembled movie; `RecorderController` gains `/sound` and tells which sources carry sound.

**Tech Stack:** as parts 1–3 — Objective-C core (`Recorder/`), SwiftUI window (`App/`), Metal, AVFoundation (now also `AVAssetWriterInput` for audio, Core Audio formats), the NDI SDK loaded at run time, SwiftPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-03-simple-recorder-design.md` — "NDI sound is recorded", "What a take writes" (sound in separate and assembled movies; AAC or linear PCM; the first two channels; the take's clock), `/sound` in "Parameters", the note sign in the sources' list and *Sound* in the settings, "MCP" (`sound`), "Tests" (a tone written and read back, in step with the picture). Not in the design: more than two channels, sound from an audio device.

## Global Constraints

- Everything parts 1–3 established stands (`DECISIONS.md` D1–D65, `CLAUDE.md`): `Recorder/` never imports Syphon nor links NDI; private headers on the module map's `exclude` list; places locked while recording; one clock per take; a movie which has frames is never deleted (D21); the test and end-to-end recipes.
- **Syphon has no sound.** Only a source which delivers sound has a sound track; a movie of a source without sound is exactly what it is today.
- **The first two channels of the source.** One channel is written to both. More than two: the first two, the others left out.
- **Format written**: 48 kHz, two channels; **AAC** (256 kbit/s) in H.264 and HEVC movies, **linear PCM** (24 bits) in ProRes movies. A source at another rate (44.1 kHz…) is converted.
- **On the take's clock**: a sound's time is its arrival, as a frame's is (D58); NDI's own timestamps are not used. The track is one unbroken stream of samples from the take's zero: what is missing is silence.
- **Separate**: each source's movie has its source's sound. **Assembled**: the sound of the source named by `/sound`, none by default (empty). **Both**: both.
- `/sound` is a setting like the others: saved, changed while recording without touching the take, applied to the next one.
- Sound never delays pictures and pictures never delay sound: sound which the encoder cannot take in time is left out (it becomes silence) and counted, as frames are (D19).
- NDI off, or a source without sound: nothing new is reported as an error.
- Every new behaviour has a test which failed first. Tests wait on conditions with a deadline. Tests which need NDI's library are skipped without it. Commits in English with the harness's `Co-Authored-By` line. Work on a branch `sound`, pushed to `origin`; merged into `master` at the end with Adrien's say.
- End-to-end runs use test ports and `-RecorderFolder`; Adrien's preferences are exported before and re-imported after; his apps are never killed; no NDI or Syphon source which is not ours is ticked.

## Review Focus

1. **A source at 44.1 kHz** (or any rate which is not 48 kHz): the pitch and the duration are right in the movie — Task 2, `testA44100HertzToneKeepsItsPitchAndLength`.
2. **One channel, and more than two**: mono is heard on both sides; of four channels the first two are kept — Task 1, `testOneChannelBecomesTwo`, `testTheFirstTwoOfSeveralChannelsAreKept`.
3. **Sound which starts after the take, stops during it, or comes back**: silence where there is none, the rest in its place, the track unbroken — Task 1, `testSilenceFillsWhatIsMissing`; Task 2, `testSoundWhichStartsLateIsPlacedOnTheMoviesClock`.
4. **The source's clock and ours drift apart over a long take**: sound stays within a tenth of a second of the pictures, by silence added or samples left out, never by a pile-up — Task 1, `testALongDriftIsCorrectedWithoutABreak`.
5. **A movie which has a sound track but received no sound** (the source carried none during the take): the movie is whole and plays — Task 2, `testAMovieWhoseSoundNeverCameIsWhole`.
6. **The encoder is behind**: sound waiting does not grow without bound, pictures are not delayed, what is left out is counted — Task 2, `testSoundIsLeftOutRatherThanPiledUp`.
7. **Quitting or stopping in the middle of a sound**: the movie is finished with its sound up to that moment — Task 2, `testFinishingKeepsTheSoundWrittenSoFar`; Task 8, SIGTERM.
8. **The source chosen for the assembled movie's sound is unticked, away, or has no sound**: the assembled movie is written without sound, or with silence; nothing fails — Task 3, `testTheAssembledMovieTakesOneSourcesSound`; Task 5, `testASoundSourceWhichIsNotThereIsNotAnError`.
9. **A source reconnected during a take** (its sender relaunched): its sound resumes in the same track, in step — Task 5, `testSoundResumesAfterTheSourceComesBack`; Task 8.
10. **Sound in step with the picture**: a click sent with a flash is found within one frame of it in the movie — Task 4, `testSoundAndPictureAreInStep`; Task 8, measured on the signed app.

## File Structure

| File | Responsibility |
|---|---|
| `Recorder/SourceSound.{h,m}` | a piece of sound as a source delivers it: two channels of float samples, their rate; made from planar or interleaved samples of any channel count |
| `Recorder/SoundTimeline.{h,m}` | where each piece goes in the track: one unbroken stream; silence added or samples left out when clocks part (pure) |
| `Recorder/FrameSource.h` | + `soundHandler`, `hasSound` (optional: Syphon has neither) |
| `Recorder/MovieRecorder.{h,m}` | + a sound track: settings, `appendSound:atTime:`, the audio input, counts |
| `Recorder/Take.{h,m}` | + which sources have sound, whose sound the assembled movie takes, `appendSound:fromSourceAtIndex:atTime:` |
| `Recorder/NDISource.{h,m}` | + audio frames received and given as `SourceSound` |
| `Recorder/RecorderController.{h,m}` | + a place's sound, `/sound`, `/status/source/N/sound`, `/status/sound/…` |
| `App/RecorderModel.swift`, `App/Views/{SourcesSidebar,InspectorView}.swift` | the note sign; *Sound* in "Assembled" |
| `MCP/main.swift` | + `sound` |
| `Tests/NDITestSupport/NDITestSender.{h,m}` | + sends a tone, a click |
| `Tools/ndi-send.m`, `Tools/movie-info.swift` | `--tone`: a click with a flash each second; the sound track's details and where its clicks are |
| `Tests/RecorderKitTests/{SourceSound,SoundTimeline}Tests.swift`, `SoundInfo.swift`, extended `MovieRecorder`, `Take`, `NDISource`, `RecorderController` tests | |

---

### Task 1: A piece of sound, and where it goes

Pure code: no AVFoundation, no NDI, no threads.

**Files:** Create `Recorder/SourceSound.{h,m}`, `Recorder/SoundTimeline.{h,m}`, `Tests/RecorderKitTests/{SourceSound,SoundTimeline}Tests.swift`; add both headers to `Recorder/RecorderKit.h`.

**Interfaces — Produces:**

```objc
/*
 A piece of sound: two channels of floating-point samples, interleaved (left, right, left…).
 */
@interface SourceSound : NSObject
// planes: channelCount pointers to frameCount floats each (as NDI gives them: stride in bytes between planes).
// One channel is copied to both; of more than two the first two are kept. nil if there is nothing to keep.
+ (nullable instancetype)soundWithPlanarSamples:(const float *)samples
                                   channelCount:(NSUInteger)channelCount
                                     frameCount:(NSUInteger)frameCount
                           channelStrideInBytes:(NSUInteger)stride
                                     sampleRate:(double)sampleRate;
// Interleaved stereo, as tests and the timeline make it
+ (nullable instancetype)soundWithInterleavedStereoSamples:(const float *)samples
                                                frameCount:(NSUInteger)frameCount
                                                sampleRate:(double)sampleRate;
+ (instancetype)silenceOfFrameCount:(NSUInteger)frameCount sampleRate:(double)sampleRate;
@property (readonly) double sampleRate;         // of the source: 48000, 44100…
@property (readonly) NSUInteger frameCount;     // samples in each channel
@property (readonly) const float *samples;      // frameCount × 2 floats
@property (readonly) NSTimeInterval duration;
// The frames from one index on (nil if none is left): for the timeline, which leaves samples out
- (nullable SourceSound *)soundFromFrame:(NSUInteger)frame;
@end

/*
 Places pieces of sound, which arrive at moments of our clock but were made on their source's, in one unbroken
 stream of samples which begins at the track's zero.
 */
@interface SoundTimeline : NSObject
// origin: the time which is sample 0, on the clock of the times given below
- (instancetype)initWithOrigin:(NSTimeInterval)origin;
// The pieces to write for a piece which arrived at a time, in order, each following the last sample written:
// usually the piece itself; silence then the piece when sound is late by more than the tolerance (it starts late,
// it was away, it was left out); the piece less its first samples, or nothing, when it is early by more.
// A piece which ends before the origin gives nothing. A change of sample rate starts a new run at the time given.
- (NSArray<SourceSound *> *)piecesForSound:(SourceSound *)sound arrivedAtTime:(NSTimeInterval)time;
// Where the next sample goes, in seconds from the origin
@property (readonly) NSTimeInterval writtenDuration;
// Seconds of silence added and of sound left out so far
@property (readonly) NSTimeInterval silenceAdded;
@property (readonly) NSTimeInterval soundLeftOut;
@end
```

A piece arrives when its last sample has been made: its place by our clock is `time − duration`. The tolerance is 0.1 s: while the stream's end is within 0.1 s of that place the piece simply follows (no correction: arrival times jitter by more than a sample); beyond it, the stream is brought back exactly onto the clock.

- [ ] **Step 1:** tests, `SourceSoundTests`: `testTwoPlanesAreInterleaved`; `testOneChannelBecomesTwo`; `testTheFirstTwoOfSeveralChannelsAreKept` (four planes with a stride larger than a plane); `testNothingGivesNothing` (0 frames, 0 channels, NULL, a rate of 0); `testSilenceIsZeros`; `testAPieceCanBeCutFromAFrameOn`. `SoundTimelineTests`: `testPiecesWhichFollowAreWrittenAsTheyAre` (twenty pieces of 1024 frames arriving on time: twenty pieces out, nothing added, `writtenDuration` exact); `testJitterWithinTheToleranceChangesNothing` (arrivals ±40 ms); `testSoundWhichStartsLateIsPrecededBySilence` (first piece at origin + 0.5 s: silence of 0.5 s less the piece's length, then the piece); `testSilenceFillsWhatIsMissing` (pieces, then none for 2 s, then pieces: one silence of about 2 s between); `testSoundBeforeTheOriginIsLeftOut` (and a piece which straddles the origin is cut); `testAnEarlyPieceIsCutOrLeftOut`; `testALongDriftIsCorrectedWithoutABreak` (one hour of pieces from a source whose clock is 100 ppm fast, then 100 ppm slow: the end of the stream never leaves the clock by more than 0.1 s plus a piece; `silenceAdded` or `soundLeftOut` near 0.36 s; every piece out follows the one before); `testAChangeOfRateStartsAgainOnTheClock`.
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Add SourceSound and SoundTimeline: a source's sound on a movie's clock".

### Task 2: A sound track in a movie

The part's unknowns are here, and are settled by measurement before the code is kept: whether `AVAssetWriterInput` converts 44.1 kHz floats to 48 kHz AAC by itself; what a writer does with an audio input which received nothing; whether an audio input can be given its format before any sound has come.

**Files:** Modify `Recorder/MovieRecorder.{h,m}`, `Tests/RecorderKitTests/MovieRecorderTests.swift`; create `Tests/RecorderKitTests/SoundInfo.swift` (test support: reads a movie's sound track — codec, rate, channels, duration, when sound which is not silence begins, the samples as floats, the frequency of a tone by its zero crossings).

**Interfaces — Consumes** Task 1. **Produces:**

```objc
// MovieRecorderSettings
// The movie has a sound track: AAC (256 kbit/s) with h264 and hevc, linear PCM (24 bits) with ProRes; 48 kHz, two channels.
@property (assign) BOOL recordsSound;

// MovieRecorder
// A piece of sound which arrived at a time on the clock of appendTexture:…. Any thread; returns at once.
// Does nothing if the movie has no sound track or is not recording.
- (void)appendSound:(SourceSound *)sound atTime:(NSTimeInterval)time;
@property (readonly) NSTimeInterval soundWritten;   // seconds of sound in the track, silence included
@property (readonly) NSTimeInterval soundLeftOut;   // seconds left out because the encoder could not take them in time
```

The audio input is added when the writer is made, so the track's format is fixed there (48 kHz stereo) whatever the source sends. Sound goes through a `SoundTimeline` whose origin is the movie's time zero, on the recorder's queue, then to the input as `CMSampleBuffer`s of linear PCM floats. When the input is not ready, pieces wait (two seconds of sound at most); beyond that the oldest are left out, counted, and the timeline fills their place with silence when sound is written again. Sound which arrives before the writer exists (a movie whose size waits for its first frame) waits in the same way. `finishAtTime:` writes what waits, then marks the audio input finished with the video's. A movie which received sound but no frame is still "no frame was received": it has no file (D39 unchanged).

- [ ] **Step 1 (measure, in a scratch test which is not kept):** write, with a bare `AVAssetWriter`, (a) 44.1 kHz stereo float buffers into an AAC 48 kHz input and into a 24-bit PCM 48 kHz input — does it convert, is the pitch right; (b) a movie with frames and an audio input which never receives a buffer, finished — does it finish, does the movie open, has it a sound track; (c) the same with silence written. Ledger what was seen. Rulings which follow from it: if the writer does not convert rates, `MovieRecorder` converts with `AVAudioConverter` before the input; if an input left empty breaks or bloats the movie, the recorder writes silence up to the movie's end at `finishAtTime:` (the timeline does it: a zero-length piece arriving at the end).
- [ ] **Step 2:** tests, each reading the movie back with `SoundInfo`: `testAToneIsWrittenAndReadBack` (1 kHz, 2 s, with frames, h264: an AAC track, 48 kHz, 2 channels, about 2 s, about 1 kHz); `testProResMoviesHaveLinearPCM` (prores422: `lpcm`, 24 bits); `testA44100HertzToneKeepsItsPitchAndLength`; `testSoundWhichStartsLateIsPlacedOnTheMoviesClock` (start time 100, frames from 100, sound from 100.5: sound which is not silence begins at 0.5 s ± 0.03); `testTwoMoviesOfATakeHaveTheirSoundInStep` (two recorders, one start time, a click sent to both at the same time: found at the same place ± a frame); `testAMovieWithoutSoundIsAsBefore` (`recordsSound` NO: no sound track; `appendSound` does nothing); `testAMovieWhoseSoundNeverCameIsWhole`; `testSoundWhichStopsLeavesTheRestSilentOrShort` (the movie plays to its pictures' end); `testSoundIsLeftOutRatherThanPiledUp` (ten seconds of sound given at once, before any frame: `soundLeftOut` is about eight; pictures appended afterwards are all written); `testFinishingKeepsTheSoundWrittenSoFar`; `testSoundDoesNotCountAsAFrame` (sound and no frame: finish reports that no frame was received, no file).
- [ ] **Step 3–5:** fail, implement, pass; whole suite. **Step 6:** commit "A movie can have a sound track".

### Task 3: A take with sound

**Files:** Modify `Recorder/Take.{h,m}`, `Tests/RecorderKitTests/TakeTests.swift`.

**Interfaces — Consumes** Task 2. **Produces:**

```objc
// soundSources: the indexes of the sources whose movies have a sound track: no other has one.
// assembledSoundIndex: the source whose sound the assembled movie takes; NSNotFound for none. It need not be in
// soundSources for TakeOutputAssembled, where the sources have no movies.
- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles sizes:(NSArray *)sizes output:(TakeOutput)output
                assembledSize:(NSSize)assembledSize soundSources:(NSIndexSet *)soundSources
          assembledSoundIndex:(NSUInteger)assembledSoundIndex name:(NSString *)name folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings atTime:(NSTimeInterval)time error:(NSError **)error;
// A source's sound: to its own movie if it has a sound track, and to the assembled movie if it is the one. Any thread.
- (void)appendSound:(SourceSound *)sound fromSourceAtIndex:(NSUInteger)index atTime:(NSTimeInterval)time;

// TakeMovie
@property (readonly) BOOL hasSound;
@property (readonly) NSTimeInterval soundWritten;
@property (readonly) NSTimeInterval soundLeftOut;
```

The earlier `start…` methods call this one with no sound. The settings given are copied for each movie, with `recordsSound` set for those which have a track.

- [ ] **Step 1:** tests: `testASourcesSoundGoesToItsMovie` (two sources, the second with sound: only its movie has a sound track; a tone sent to index 1 is in it); `testSoundFromASourceWithoutATrackIsIgnored`; `testTheAssembledMovieTakesOneSourcesSound` (`both`, three sources, sound from 1 and 2, assembled takes 2: the assembled movie has 2's tone, not 1's; each source's movie has its own); `testAssembledAloneTakesTheSound` (`assembled`: one file, with the sound); `testNoSourceChosenLeavesTheAssembledMovieSilent` (no sound track at all); `testAllTheMoviesOfATakeShareItsClockForSoundToo` (a click sent to two sources at one time is at the same place in three movies); `testAnIndexWhichIsNotASourceIsIgnored`.
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "A take routes each source's sound to its movies".

### Task 4: NDI sound received

**Files:** Modify `Recorder/FrameSource.h`, `Recorder/NDISource.{h,m}`, `Tests/NDITestSupport/NDITestSender.{h,m}`, `Tests/RecorderKitTests/NDISourceTests.swift`; the fakes of both test targets and `App/SyphonSources.swift` (protocol conformance only).

**Interfaces — Consumes** Task 1. **Produces:**

```objc
// FrameSource
// Called for every piece of sound, on any thread; whoever receives it notes when it arrived, as for a frame.
// A source which has no sound never calls it.
@property (copy, nullable) void (^soundHandler)(SourceSound *sound);
// YES once the source has delivered sound, and for as long as it goes on (NO again after three seconds without)
@property (readonly) BOOL hasSound;

// NDITestSender
// Sound sent from now on beside the picture: a sine of a frequency, or silence with a click (one full-scale
// sample pulse of 5 ms) each time -click is called; channels 1, 2 or 4; any rate. Sent in pieces of 20 ms.
- (void)sendToneOfFrequency:(double)frequency channelCount:(int)channels sampleRate:(int)rate;
- (void)sendSilenceWithClicksOfChannelCount:(int)channels sampleRate:(int)rate;
// A click now, and — if the picture is marked — the whole picture white for the frame sent at the same moment
- (void)click;
- (void)stopSound;
```

`NDISource` asks `recv_capture_v3` for audio again (`NDIlib_audio_frame_v3_t`, planar floats `FLTP`; another FourCC is freed and left out, said once in the log), makes a `SourceSound` with `channel_stride_in_bytes`, calls `soundHandler` under the same guard as `frameHandler` (none after `stop` returns), and frees the frame on every path. `SyphonSource` and the fakes answer nil and NO; the fakes gain `deliverSound(_:)`.

- [ ] **Step 1:** tests (skipped without the library; own senders only): `testATonesPitchArrives` (a 1 kHz tone sent: pieces arrive at 48 kHz, their zero crossings say 1 kHz); `testOneChannelArrivesAsTwo`; `testFourChannelsArriveAsTheFirstTwo` (different frequencies on each channel); `testA44100HertzSenderIsGivenAsItIs`; `testHasSoundFollowsTheSender` (NO for a sender of pictures only; YES within 5 s once it sends sound; NO again within 5 s after `stopSound`); `testNoSoundIsDeliveredAfterStop`; `testASenderOfPicturesOnlyIsReceivedAsBefore`; `testSoundAndPictureAreInStep` (a sender of silence with clicks and marked pictures, `click` five times a second apart; a `MovieRecorder` fed by the source's two handlers with their arrival times, `recordsSound` YES: in the movie each click is within 50 ms of the first white picture which follows — the figure measured is ledgered, with what NDI itself adds).
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "Receive an NDI source's sound".

### Task 5: The controller: which sources have sound, whose the assembled movie takes

**Files:** Modify `Recorder/RecorderController.{h,m}`, `Tests/RecorderKitTests/RecorderControllerTests.swift`.

**Interfaces — Consumes** Tasks 3–4. **Produces:**

```objc
// RecorderPlace
@property (readonly) BOOL hasSound;                    // /status/source/N/sound (i): its source is delivering sound
@property (readonly) NSTimeInterval soundWritten;      // in its movie, of the take being recorded or of the last

// RecorderController
// /sound: the title of the source whose sound goes in the assembled movie; empty for none. Saved.
// Set with a title or a part of one, as a place is; it must be one of the sources chosen. A name which matches none
// changes nothing and is reported.
@property (nonatomic, copy) NSString *sound;
// /status/sound/written (f), /status/sound/leftout (f): seconds of sound in the assembled movie; seconds left out in all the movies
@property (readonly) NSTimeInterval assembledSoundWritten;
@property (readonly) NSTimeInterval soundLeftOut;
```

`connectPlace:` sets the source's `soundHandler`: the place notes that sound arrived (for `hasSound`, as it notes frames for `online`), and, while a take is recorded, gives it to the take with the place's index and `CACurrentMediaTime()`. When a take starts: the sources whose movies have a sound track are the places which have sound **at that moment**, and every place of kind NDI whose source is away or has not yet been heard (an NDI source may bring its sound when it arrives: its movie has a track, silent if nothing comes — the measurements of Task 2 say what that costs); the assembled movie takes the sound of the place whose title is `sound`, if it is among them. `/sound` is `RANGE`d with the titles of the places chosen (and an empty string). Unticking the source named by `sound` leaves the setting as it is: it applies again if the source is ticked again; meanwhile the assembled movie has no sound, and this is no error.

- [ ] **Step 1:** tests with the fakes: `testAPlaceSaysWhetherItHasSound` (and stops saying so three seconds after the last piece); `testSoundIsEmptyByDefaultAndSaved`; `testOSCSetsSoundByATitleOrAPartOfIt` (and `/sound ""` clears it; a name which matches no source chosen is refused with an error naming it); `testASourcesSoundIsInItsMovie` (a fake NDI source with sound, a fake Syphon one: separate take, the first movie has a sound track with the tone, the second none); `testTheAssembledMovieHasTheSoundChosen`; `testWithoutASoundChosenTheAssembledMovieHasNone`; `testASoundSourceWhichIsNotThereIsNotAnError` (`sound` names a source which was unticked: the take starts, the assembled movie has no sound track, `error` empty); `testChangingSoundWhileRecordingAppliesToTheNextTake`; `testSoundResumesAfterTheSourceComesBack` (the fake source is killed and relaunched during a take, sound before and after: one track, silence between, the sound after in its place ± 0.1 s); `testAnNDIPlaceWhichIsAwayAtTheStartStillRecordsItsSoundWhenItArrives`; `testOSCQueryDescribesSound` (`/sound` with its `VALS`, `/status/source/1/sound`, `/status/sound/written`, `/status/sound/leftout`); update `testOSCQueryDescribesEveryParameter`.
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "Record the sound of NDI sources; /sound for the assembled movie".

### Task 6: The window

**Files:** Modify `App/RecorderModel.swift`, `App/Views/{SourcesSidebar,InspectorView}.swift`, `Tests/SimpleRecorderTests/{Fakes,RecorderModelTests,ViewRenderingTests}.swift`.

- **Model**: `Place.hasSound`, `sound` (the title chosen, empty for none), `setSound(_:)`, `soundLeftOut`.
- **Sidebar**: a ticked source which has sound carries a note sign (`music.note`) beside its NDI tag; a tool tip says "Its sound is recorded in its movie".
- **Inspector**, section "Assembled", under Gap: *Sound* — a picker: "None", then the titles of the places which are NDI sources (with sound or not: sound may come); a title which is chosen but no longer among the places is shown, dimmed, as "*title* (not selected)". Disabled while recording, like Size and Gap. Dimmed altogether when the output is Separate.
- **Take bar**: when sound was left out during the take, the caption adds "· *n* s of sound lost", in the accent colour, as dropped frames are.

- [ ] **Step 1:** model tests: `testSoundFollowsTheControllerBothWays`; `testAPlaceSaysItHasSound`; `testTheCaptionSaysWhenSoundWasLost` (in `TakeCaptionTests`).
- [ ] **Step 2:** rendered views (`build/views/`): `10-sound` (two NDI places, one with sound and chosen for the assembled movie, output Both) and `11-sound-not-selected` — **read the pictures**: the note sign on the right row only, the picker's text, nothing displaced.
- [ ] **Step 3–4:** implement until green and the pictures are right. **Step 5:** commit "Sound in the window".

### Task 7: MCP, tools, documentation

**Files:** Modify `MCP/main.swift`, `Tools/ndi-send.m`, `Tools/movie-info.swift`, `README.md`, `DECISIONS.md`, `CLAUDE.md`.

- [ ] **Step 1:** `ndi-send … --tone`: beside the picture, 48 kHz stereo sound — a 440 Hz tone on the left, 880 Hz on the right, at −12 dB, and each second a click of 5 ms at full scale sent with a picture which is white all over (the "flash"), so that step between sound and picture can be measured in a movie. `--rate 44100`, `--channels 1|2|4`. `movie-info`: each movie's sound track (codec, rate, channels, duration, where sound which is not silence begins); `--sync` prints, for a movie made from `ndi-send --tone`, the time of each flash and of each click and their difference.
- [ ] **Step 2:** MCP: `recorder_configure` / `recorder_start` take `sound` (a title, or empty); `recorder_status` gives `settings.sound`, `sources[].sound` (true/false), `assembled.soundWritten`, `soundLeftOut`; the descriptions say what has sound and where it goes.
- [ ] **Step 3:** README (what is recorded with sound, the format, `/sound` and the new status addresses, the limits: two channels, NDI only), `DECISIONS.md` (D66…: sound's time is its arrival and the track is one unbroken stream — the tolerance and why; 48 kHz stereo fixed when the writer is made; which movies get a track, and the silent track of an NDI source which sent no sound; sound left out rather than delaying pictures; `/sound` kept when its source is unticked; what Task 2 measured of `AVAssetWriter`; the step between sound and picture measured), `CLAUDE.md` (the four parts done; the rules this part cost).
- [ ] **Step 4:** `swift test`, `Tools/build.sh`, `Scripts/bundle.sh`. **Step 5:** commit "MCP, tools and documentation for sound".

### Task 8: End to end, review

- [ ] **Step 1:** Adrien's preferences exported. The signed bundle on test ports; `ndi-send T1 1280 720 30 --tone`, `ndi-send T2 960 540 60 --tone --rate 44100 --channels 1`, `ndi-send N3` (no sound), a Syphon sender. Status over OSCQuery and MCP: which places have sound.
- [ ] **Step 2:** `separate`, h264, 10 s → T1's and T2's movies have AAC sound, the others none; `movie-info --sync`: each click within a frame and a half of its flash; pitches 440/880 Hz in T1, 440 on both sides in T2. `prores422` → linear PCM.
- [ ] **Step 3:** `both`, `/sound` T2 → the assembled movie has T2's sound, in step with T2's part of the picture; `/sound ""` → none.
- [ ] **Step 4:** kill `ndi-send T1` during a take and relaunch it → one sound track, silence while it was away, in step afterwards. `kill -TERM` the app during a take with sound → every movie finished, with its sound up to that moment.
- [ ] **Step 5:** ten minutes, `both`, HEVC, assembled fitted to 3840 × 2160: `soundLeftOut` 0, the last click still within a frame and a half of its flash (drift), frames dropped noted.
- [ ] **Step 6:** `SIMPLE_NDI_LIBRARY=/nonexistent`: as before, nothing about sound is an error.
- [ ] **Step 7:** MCP over stdio: configure `sound`, start, stop, status.
- [ ] **Step 8:** Adrien's preferences re-imported, keys added by the run removed, test processes killed by PID.
- [ ] **Step 9:** whole-branch review by a fresh reviewer, with this plan's Review Focus; one fix pass, each fix with a test which failed first; the smoke take redone on the rebuilt bundle; commit; push `sound`.
