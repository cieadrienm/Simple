# Simple Recorder, part 2: the assembled movie — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A recording can write one movie in which the sources are assembled — side by side, stacked, in a mosaic, or one large with the others beside it — instead of, or as well as, one movie per source; and the window shows that picture as it is recorded.

**Architecture:** Two new pieces in the Objective-C core: `Layout`, pure, which says where each source goes and how large the picture is; `Compositor`, which draws the sources' latest frames into one Metal texture. `RecorderController` composes each time its clock source delivers a frame and gives the result to the take, whose `Take` now holds an assembled movie beside (or instead of) the sources' own. The window's monitor becomes that one texture with the sources' titles laid over it, and gains the layout picker and the output choice.

**Tech Stack:** as part 1 — Objective-C core (`Recorder/`), SwiftUI window (`App/`), Metal, AVFoundation, SwiftPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-03-simple-recorder-design.md` — "What a take writes", "Layouts", the `/output`, `/layout`, `/gap`, `/width`, `/height` and `/status/assembled/…` rows of "Parameters", the middle and right of "The window". Sound (`/sound`) is part 4; NDI is part 3.

## Global Constraints

- Everything part 1 established stands (see its plan and `DECISIONS.md` D35–D47): macOS 14, `Recorder/` without Syphon, places locked while recording, one clock per take, D19/D21/D22/D26/D27/D33, the test and end-to-end recipes of `CLAUDE.md`.
- Outputs `separate`, `assembled`, `both`; **default `separate`**, so that what is recorded today is unchanged until the choice is made.
- Layouts `row`, `column`, `grid`, `focus`; default `row`. Gap in pixels, default 0, 0…512.
- `/width`, `/height`: the size the assembled picture is fitted into; 0 (either) for automatic. A source's own movie is always its source's size.
- Background black; transparent when the codec is `prores4444`. Sources are copied, not blended.
- A source never seen counts as 1920 × 1080. Dimensions are even.
- Output, layout, gap and size changed while recording apply to the next recording, like every setting: the take's picture is decided when it starts.
- Names: assembled `<name>.mov`; a source's own `<name> — <title>.mov`, except a take of one source which is not assembled: `<name>.mov`.
- Every new behaviour has a test which failed first. Commits in English with the harness's `Co-Authored-By` line. Work on a branch `assembled`, pushed to `origin`; merged into `master` at the end with Adrien's say.

## Review Focus

1. **A source changes size during a take** (its window is resized): the picture keeps its size and its places; the source is fitted into its own — Task 5, `testASourceWhichChangesSizeStaysInItsPlace`.
2. **The clock source goes away during a take**: the next source which delivers drives the picture; the movie goes on — Task 5, `testTheNextSourceDrivesThePictureWhenTheFirstGoesAway`.
3. **A source is away when the take starts**: its place is black, as large as it was last seen, or as 1920 × 1080 — Task 1, `testASourceNeverSeenCountsAs1080p`; Task 5, `testASourceWhichIsAwayLeavesItsPlaceBlack`.
4. **A picture too large for the codec** (eight 1080p sources in a row are 15360 wide; H.264 stops near 4096): the take does not start, and says why and what to do; in `both`, no source's movie is started either — Task 4, `testAnAssembledPictureTheCodecCannotWriteStartsNothing`.
5. **Layout, gap, size or output changed during a take**: the take is unchanged; the next one has them — Task 5, `testChangingTheLayoutWhileRecordingAppliesToTheNextTake`.
6. **One source**: assembled alone is `<name>.mov`; `both` writes `<name>.mov` and `<name> — <title>.mov` — Task 4, `testNamesForEachOutput`.
7. **Transparency**: with ProRes 4444 the gaps are transparent and a source's own transparency is kept, not blended onto black — Task 2, `testTransparencyIsKept`; Task 4, `testAnAssembledProRes4444MovieIsTransparentBetweenSources`.
8. **The encoder falls behind**: a composite waiting to be encoded is not drawn over by the next one — Task 2, `testACompositeIsNotOverwrittenByTheNextOnes`.

## File Structure

| File | Responsibility |
|---|---|
| `Recorder/Layout.{h,m}` | the four layouts: the picture's size and each source's rectangle (pure) |
| `Recorder/Compositor.{h,m}` | sources' textures → one texture, by a layout (Metal) |
| `Recorder/FramePacer.{h,m}`, `MovieRecorder.{h,m}` | + asking whether a frame would be kept, before composing it |
| `Recorder/Take.{h,m}` | + output, the assembled movie, names |
| `Recorder/RecorderController.{h,m}` | + output, layout, gap, the composition, `/status/assembled/…` |
| `App/RecorderModel.swift` | + output, layout, gap, size, the assembled picture's state |
| `App/Views/MonitorView.swift` | the assembled picture and the titles over it; the layout picker and size under it |
| `App/Views/TakeBar.swift` | + the output choice |
| `App/Views/InspectorView.swift` | + "Assembled": size, gap |
| `MCP/main.swift` | + `output`, `layout`, `gap`, `width`, `height`; the assembled movie in the status |
| `Tests/RecorderKitTests/{Layout,Compositor}Tests.swift`, extended `Take`, `RecorderController` tests | |
| `Tests/SimpleRecorderTests/*` | model and rendered views |

---

### Task 1: Layout

**Files:** Create `Recorder/Layout.{h,m}`, `Tests/RecorderKitTests/LayoutTests.swift`; add to `Recorder/RecorderKit.h`.

**Interfaces — Produces:**

```objc
typedef NS_ENUM(NSInteger, LayoutKind) {
    LayoutKindRow,      // side by side
    LayoutKindColumn,   // stacked
    LayoutKindGrid,     // a mosaic
    LayoutKindFocus     // the first large, the others in a column on its right
};

// Where the sources go in the assembled picture
@interface Layout : NSObject
// "row", "column", "grid", "focus"
+ (NSArray<NSString *> *)kindNames;
+ (NSString *)nameForKind:(LayoutKind)kind;
+ (BOOL)getKind:(LayoutKind *)kind forName:(NSString *)name;

// sourceSizes: the size of each source's frames (NSValue of NSSize); NSNull, or a size with a zero, for a source
// never seen, which counts as 1920 × 1080.
// fittingSize: the size the picture is fitted into without distortion; zero (either dimension) for the automatic size.
+ (instancetype)layoutOfKind:(LayoutKind)kind
                 sourceSizes:(NSArray *)sourceSizes
                         gap:(NSInteger)gap
                 fittingSize:(NSSize)fittingSize;

// The size of the picture, in pixels: even numbers
@property (readonly) NSSize size;
// The rectangle of each source's picture, in pixels, origin at the top left, in the order of the sources
@property (readonly, copy) NSArray<NSValue *> *frames;
@end
```

Automatic sizes, for sources in order (spec, "Layouts"): **row** — every source scaled to the height of the tallest, widths added, gaps between; **column** — every source scaled to the width of the widest, heights added; **grid** — ⌈√n⌉ columns, every cell the size of the largest source (largest width, largest height), each source fitted and centred in its cell, the last row left-aligned; **focus** — the first at its own size, the others sharing its height (less the gaps) in a column on its right, each fitted in its share, the column as wide as the widest of them. One source: that source alone, whatever the kind. With a fitting size: the automatic layout scaled by one factor to fit, centred. Rectangles are rounded to whole pixels; no rectangle is empty.

- [ ] **Step 1:** tests: `testOneSourceIsItselfWhateverTheKind`; `testRowScalesToTheTallest` (1920×1080 + 512×520 → both 1080 high; the second 1063 wide (1063.4), at x 1920; the picture 2984 × 1080, its width rounded up to an even number); `testRowWithAGap`; `testColumnScalesToTheWidest`; `testGridOfThreeIsTwoByTwoCellsOfTheLargest`; `testGridFitsEachSourceInItsCell` (a 512×520 source centred in a 1920×1080 cell); `testFocusPutsTheOthersInAColumn` (three sources: frames and size); `testFocusWithOneOtherSource`; `testASourceNeverSeenCountsAs1080p` (NSNull and `{0,0}`); `testAFittingSizeScalesAndCentresThePicture` (row of two 1920×1080 into 1920×1080 → size 1920×1080, frames `{0,270,960,540}` `{960,270,960,540}`); `testSizesAreEven`; `testEightSources` (every kind: eight frames, none empty, none overlapping, all inside the picture); `testKindNames`.
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Add Layout: where the sources go in the assembled picture".

### Task 2: Compositor

**Files:** Create `Recorder/Compositor.{h,m}`, `Tests/RecorderKitTests/CompositorTests.swift`.

**Interfaces — Consumes** `Layout`. **Produces:**

```objc
@interface Compositor : NSObject
// The compositor draws with this queue, on its device
- (instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue;
// Draws the sources into a texture of the layout's size and returns it.
// textures: one for each source of the layout, NSNull for a source with no picture: its place stays empty.
// flipped: for each, an NSNumber: YES if the texture's first row is the bottom of its picture.
// transparent: the background is transparent instead of black, and a source's transparency is kept.
// The texture returned is not drawn to again by the next three calls: it can wait to be encoded.
// Can be called from any thread, one call at a time.
- (nullable id<MTLTexture>)compose:(Layout *)layout
                          textures:(NSArray *)textures
                           flipped:(NSArray<NSNumber *> *)flipped
                       transparent:(BOOL)transparent;
@end
```

A ring of four BGRA targets of the layout's size (remade when the size changes); one render pass: clear, then one quad for each source at its rectangle; no blending (a source's pixels replace the background, alpha included; without `transparent`, alpha is written as 1).

- [ ] **Step 1:** tests, reading the composite back (the test commits an empty command buffer on the compositor's own queue and waits for it: a queue runs its buffers in order, so the composite is drawn by then): `testEachSourceIsInItsPlace` (three solid colours, row: a pixel at the centre of each frame has its colour); `testGapsAreBlack`; `testAFlippedSourceIsUpright` and `testASourceWhichIsNotFlippedStaysAsItIs` (top-left quarter marker); `testASourceWithNoPictureLeavesItsPlaceBlack`; `testTransparencyIsKept` (transparent: gap alpha 0, a source's half-transparent pixel keeps its alpha; not transparent: alpha 255 everywhere); `testACompositeIsNotOverwrittenByTheNextOnes` (compose red, then three times blue: the first texture still reads red; they are four different textures); `testTheTargetFollowsTheLayoutsSize`.
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Add Compositor: the sources drawn into one picture".

### Task 3: Asking before composing

**Files:** Modify `Recorder/FramePacer.{h,m}`, `Recorder/MovieRecorder.{h,m}`, their tests.

Composing a picture which the frame-rate maximum then discards would waste the GPU (a 120 Hz clock source recorded at 30). **Produces:**

```objc
// FramePacer: what decisionForFrameAtTime: would answer, without changing anything
- (BOOL)wouldKeepFrameAtTime:(double)time;
// MovieRecorder: NO if a frame arriving now would be discarded by the frame rate, or if it is not recording.
// Any thread.
- (BOOL)wantsFrameAtTime:(NSTimeInterval)time;
```

- [ ] **Step 1:** tests: pacer `testWouldKeepAgreesWithTheDecisionAndChangesNothing` (asked any number of times, then `decision…` answers as if never asked; for capped and uncapped, with and without an origin); recorder `testWantsFrameFollowsTheFrameRate` (cap 30: wants at 0, not at 1/120, wants at 1/30 after the frame at 0 was appended; not recording → NO).
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Let a recorder say whether it would keep a frame".

### Task 4: Take with an assembled movie

**Files:** Modify `Recorder/Take.{h,m}`, `Tests/RecorderKitTests/TakeTests.swift`.

**Interfaces — Consumes** Tasks 2–3. **Produces:**

```objc
typedef NS_ENUM(NSInteger, TakeOutput) { TakeOutputSeparate, TakeOutputAssembled, TakeOutputBoth };

// Take
+ (NSArray<NSString *> *)outputNames;                    // "separate", "assembled", "both"
+ (NSString *)nameForOutput:(TakeOutput)output;
+ (BOOL)getOutput:(TakeOutput *)output forName:(NSString *)name;

// The names of a take's movies: the sources' own (empty for TakeOutputAssembled), then the assembled movie's
// (nil for TakeOutputSeparate). None exists; the same number is added to all if one did.
+ (NSArray<NSURL *> *)urlsForName:(NSString *)name sourceTitles:(NSArray<NSString *> *)titles output:(TakeOutput)output
                         inFolder:(NSURL *)folder assembledURL:(NSURL * _Nullable * _Nullable)assembledURL;

// assembledSize: the size of the assembled picture; ignored for TakeOutputSeparate.
- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles sizes:(NSArray *)sizes output:(TakeOutput)output
                assembledSize:(NSSize)assembledSize name:(NSString *)name folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings atTime:(NSTimeInterval)time error:(NSError **)error;

// NO if the assembled picture composed now would not be recorded: no assembled movie, or its frame rate discards it
- (BOOL)wantsAssembledFrameAtTime:(NSTimeInterval)time;
// The assembled picture: never flipped. Any thread.
- (void)appendAssembledTexture:(id<MTLTexture>)texture atTime:(NSTimeInterval)time;

// The sources' movies (empty for TakeOutputAssembled), in the sources' order
@property (readonly, copy) NSArray<TakeMovie *> *movies;
// nil for TakeOutputSeparate. Its sourceTitle is empty.
@property (readonly, nullable) TakeMovie *assembledMovie;
// index is NSNotFound for the assembled movie
@property (copy, nullable) void (^movieFailureHandler)(NSUInteger index, NSError *error);
```

The existing `startWithSourceTitles:sizes:name:…` calls the new one with `TakeOutputSeparate`. The assembled movie's writer is made at the start (its size is known), so a size the codec cannot write fails the start; the message adds "Choose a smaller size for the assembled movie, or HEVC or ProRes". `appendTexture:…fromSourceAtIndex:` does nothing for `TakeOutputAssembled`. `finish` succeeds if any movie, assembled included, has frames.

- [ ] **Step 1:** tests: `testNamesForEachOutput` (one and several sources × three outputs, with the numbering); `testAssembledAloneWritesOneMovieOfThePicturesSize`; `testBothWritesTheSourcesMoviesAndTheAssembledOne` (N + 1 files, the assembled one on the take's clock); `testFramesFromSourcesAreNotWrittenWhenOnlyAssembled`; `testAnAssembledPictureTheCodecCannotWriteStartsNothing` (H.264, 15360 × 1080, `both`: start fails, the message names the size, no file, not recording); `testWantsAssembledFrameFollowsTheFrameRate`; `testAnAssembledProRes4444MovieIsTransparentBetweenSources` (through `Compositor`, read back); `testTheAssembledMoviesFailureIsReportedWithNoIndex`.
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "A take can write an assembled movie".

### Task 5: Composition in RecorderController

**Files:** Modify `Recorder/RecorderController.{h,m}`, `Tests/RecorderKitTests/RecorderControllerTests.swift`.

**Interfaces — Produces:**

```objc
// Settings
@property (nonatomic, copy) NSString *output;     // /output: "separate", "assembled", "both"
@property (nonatomic, copy) NSString *layout;     // /layout: "row", "column", "grid", "focus"
@property (nonatomic, assign) NSInteger gap;      // /gap: pixels between sources
// width, height: /width, /height — the size the assembled picture is fitted into, 0 for automatic

// The assembled picture as it is now: of the take being recorded, otherwise of the settings and the sources as they are
@property (readonly) Layout *assembledLayout;                       // /status/assembled/width, /height: its size
@property (readonly, nullable) id<MTLTexture> assembledFrame;       // the last picture composed
// The assembled movie of the take being recorded, or of the last one
@property (readonly, copy) NSString *assembledFile;                 // /status/assembled/file
@property (readonly) NSUInteger assembledFrames;                    // /status/assembled/frames
@property (readonly) NSUInteger assembledDropped;                   // /status/assembled/dropped
```

`frames` and `file` become the assembled movie's when the take (current or last) has one, the first place's otherwise; `dropped` counts every movie. The parameter table gains `/output`, `/layout` (both with `VALS`), `/gap`, and the five `/status/assembled/…`.

Composition: the **clock source** is the first place, in order, which is online; the controller's refresh keeps its index (and, while no place is online, the first to deliver a frame is). When a frame arrives from the clock source: if a take is recording an assembled movie and it wants a frame at this time, compose with the take's layout and give the picture to the take; otherwise, at most thirty times a second, compose with the current layout for the monitor. The layout of a take is made when it starts, from the sizes the places have then.

- [ ] **Step 1:** tests (fakes as in part 1): `testDefaultsAreSeparateAndRow`; `testOSCSetsOutputLayoutAndGap` (and refuses unknown names, and clamps the gap); `testTheySurviveARelaunch`; `testAssembledLayoutFollowsThePlacesAndTheSettings` (two fakes of known sizes: size and frames for row, then column, then a gap, then a fitting size); `testAPictureIsComposedForTheMonitorWhenIdle` (`assembledFrame` non-nil, of the layout's size, after the clock source delivers); `testAssembledWritesOneMovie` (three sources, `assembled`: one file `<name>.mov` of the layout's size; the places have no file; `file` and `frames` are the assembled movie's); `testBothWritesEverything`; `testThePictureHasEachSourceInItsPlace` (three solid colours, `row`: the movie's first frame read back); `testASourceWhichIsAwayLeavesItsPlaceBlack`; `testASourceWhichChangesSizeStaysInItsPlace`; `testTheNextSourceDrivesThePictureWhenTheFirstGoesAway`; `testChangingTheLayoutWhileRecordingAppliesToTheNextTake`; `testAPictureTooLargeIsRefusedAtTheStart` (error names the size; state idle; places have no file); `testTheAssembledMovieFailingIsReported`; `testOSCQueryDescribesTheAssembledPicture`.
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "Compose the sources into the assembled movie".

### Task 6: The window

**Files:** Modify `App/RecorderModel.swift`, `App/Views/{MonitorView,TakeBar,InspectorView,StatusBar}.swift`, `Tests/SimpleRecorderTests/{RecorderModelTests,ViewRenderingTests}.swift`.

- **Monitor**: one `TextureView` of `assembledFrame`, fitted; over it, each source's title at the top left of its rectangle (from `assembledLayout`, scaled to the view), with "Away" or "Waiting" in a place whose source is not online. Under it: the four layouts as a segmented picker (icons, with tool tips: Side by side, Stacked, Mosaic, One large), and the picture's size.
- **Take bar**, at the right: Separate / Assembled / Both.
- **Inspector**, a section "Assembled" between Movie and Files: Size (Automatic, or 1920 × 1080, 3840 × 2160, Custom with two fields), Gap.
- **Status bar**: the number of movies follows the output (N, 1, N + 1).
- The model publishes `output`, `layout`, `gap`, `width`, `height`, the picture's size and the titles' rectangles (normalised), `movieCount`, and the assembled movie's frames and drops; the take bar's caption counts the assembled movie's frames when there is one.

- [ ] **Step 1:** model tests: `testOutputLayoutGapAndSizeFollowTheControllerBothWays`; `testMovieCountFollowsTheOutput`; `testTheTitlesRectanglesFollowTheLayout`.
- [ ] **Step 2:** rendered views (`build/views/`): three sources in each of the four layouts; recording `both`; one source away — **read the pictures** against the mock-up (the Metal picture is black off screen: the titles' places are what is checked here).
- [ ] **Step 3–4:** implement until green and the pictures are right. **Step 5:** commit "The assembled picture in the window".

### Task 7: MCP and documentation

**Files:** Modify `MCP/main.swift`, `README.md`, `DECISIONS.md`, `CLAUDE.md`.

- [ ] **Step 1:** MCP: `recorder_configure` / `recorder_start` take `output`, `layout`, `gap`, `width`, `height`; `recorder_status` gives `settings.output/layout/gap/width/height` and `assembled: {file, frames, dropped, width, height}`; the tool descriptions say what each output writes.
- [ ] **Step 2:** README (the outputs, the layouts with their automatic sizes, the new addresses, names), `DECISIONS.md` (D48…: default `separate`; the clock source; the take's layout decided at the start; too large refused, not scaled; the ring of composites; composing only frames which are kept), `CLAUDE.md` (part 2 done; parts 3–4 remain).
- [ ] **Step 3:** `swift test`, `Scripts/bundle.sh`. **Step 4:** commit "MCP and documentation for the assembled movie".

### Task 8: End to end, review

- [ ] **Step 1:** signed bundle on test ports, Simple Servers A, B, C: `/output assembled`, each layout in turn, 3 s at 30 fps → one movie each; **read a frame of each back and look at it**: the three test patterns in their places, upright (each has its marker at its own top left), the sizes as `Layout` says.
- [ ] **Step 2:** `/output both` → four movies of equal duration; `/width 1920 /height 1080` → the picture fitted, bars black; `prores4444` → transparent between sources (read back).
- [ ] **Step 3:** kill B during an assembled take and relaunch it → its place black then alive, the movie whole; kill A (the clock source) → the picture goes on with B's clock; eight sources in a row with H.264 → refused with the message, with HEVC → written, drops and CPU noted; `kill -TERM` during a `both` take → every movie finished.
- [ ] **Step 4:** MCP over stdio: configure `output`, `layout`; start; stop; status.
- [ ] **Step 5:** put Adrien's settings back (`/output separate`, `/layout row`, `/gap 0`, places emptied).
- [ ] **Step 6:** whole-branch review by a fresh reviewer; one fix pass; commit; push.
