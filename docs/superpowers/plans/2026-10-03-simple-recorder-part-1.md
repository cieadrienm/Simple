# Simple Recorder, part 1: several Syphon sources, separate movies — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simple Client becomes Simple Recorder: a SwiftUI window in which several Syphon sources are ticked and recorded together, one movie each, on one clock, driven from the window, by OSC and by MCP.

**Architecture:** The Objective-C core in `Recorder/` gains what a source is (`FrameSource`, `SourceDirectory`), a `Take` (the movies of one recording, their names and their clock), and places (`/source/1…8`) in `RecorderController`. The app becomes a SwiftPM executable (`App/`, SwiftUI) which gives the core its Syphon sources and shows its state; Syphon reaches SwiftPM as an xcframework built from the submodule. `Scripts/bundle.sh` makes the signed `.app`.

**Tech Stack:** Objective-C (ARC) core, Swift 5 / SwiftUI app, Metal, AVFoundation, SwiftPM, XCTest; Xcode only for Syphon's framework and Simple Server.

**Spec:** `docs/superpowers/specs/2026-10-03-simple-recorder-design.md` (part 1 of its "In four parts"). Parts 2–4 (assembled movie, NDI pictures, NDI sound) get their own plans once this one has landed.

**Proved before writing this plan** (in a scratch directory, 2026-10-03): `xcodebuild -create-xcframework` on the submodule's Release framework gives a universal `Syphon.xcframework`; a SwiftPM package with `.binaryTarget(path:)`, the `Recorder` Objective-C target and a Swift executable importing `SwiftUI`, `RecorderKit` and `Syphon` builds, runs, is testable from a test target, and builds universal with `--arch arm64 --arch x86_64`. SwiftPM links Syphon with `@rpath` and an rpath of `@loader_path`: the bundle needs `@executable_path/../Frameworks` added.

## Global Constraints

- macOS 14.0 minimum; universal binaries.
- `Recorder/` is Objective-C and never imports Syphon. Swift lives in `App/`, `MCP/`, `Tests/`, `Tools/`.
- App name **Simple Recorder**, identifier `net.am-cb.simple-recorder`, OSCQuery name "Simple Recorder".
- Ports: OSC 9230, OSCQuery 9231, next free; `SIMPLE_OSC_PORT`, `SIMPLE_OSCQUERY_PORT` override.
- At most 8 places. Only ticked sources are connected to.
- Codecs `h264`, `hevc`, `prores422`, `prores4444`; `.mov`.
- What holds today keeps holding: D19 (drops counted, never delaying the source), D21 (a movie with frames is never deleted), D22 (`/status/error` vs `/status/failure`), D25 (names stay in the folder, nothing overwritten), D26 (quit and SIGTERM finish the movies), D27, D33 (unknown addresses reported).
- Never kill Adrien's apps; test instances on ports 19230/19231 with `-RecorderFolder <scratch>`; put back any setting sent by OSC to his preferences.
- No access to the screen: views are checked by rendering them off screen.
- Every new behaviour has a test which failed first. Commits in English with the harness's `Co-Authored-By` line; `git push origin master` (GitHub and Gitea).

## Review Focus

1. **A ticked source which is away when the take starts and arrives later**: its movie starts when it arrives, at the right time on the take's clock — Task 3, `testAMovieWhichStartsLateIsPlacedOnTheTakesClock`.
2. **A source which goes away during the take and comes back**: its movie goes on (last frame held), the place stays its own — Task 4, `testASourceWhichComesBackGoesOnInItsPlace`; end to end in Task 8.
3. **Places changed during a take** (OSC or window): refused, with an error; nothing in the take changes — Task 4, `testPlacesCannotChangeWhileRecording`.
4. **The same source asked for in two places**: it moves, it is not doubled — Task 4, `testASourceIsInOnePlaceOnly`.
5. **A take in which no source delivers a frame**: no file, `/status/failure` says so; a take in which one source of three never arrives: two movies, no failure — Task 3, `testASourceWhichNeverArrivesLeavesNoFileAndIsNotAFailure`, `testATakeWithNoFrameAtAllFails`.
6. **What drives Simple Client today**: `/source "x"`, `/record 1`, `/record 0`, and a one-source take named "Depth" still writes `Depth.mov` — Task 4, `testSourceIsAnAliasOfTheFirstPlace`; Task 3, `testOneSourceTakesTheNameAlone`.
7. **Eight sources of 1080p**: movies are written, drops are counted, the window stays responsive — Task 8, measured, not asserted.
8. **Preferences from Simple Client**: copied once, never again — Task 7, `testSettingsAreMigratedOnce`.

## File Structure

| File | Responsibility |
|---|---|
| `Scripts/syphon.sh` | builds `build/Syphon.xcframework` from the submodule (skips if up to date) |
| `Package.swift` | `Syphon` (binary), `RecorderKit`, `SimpleRecorder` (`App/`), `simple-recorder-mcp`, tests |
| `Recorder/FrameSource.h` | protocols `FrameSource`, `SourceDirectory`; `SourceDescription` |
| `Recorder/FramePacer.{h,m}` | + a time origin given from outside |
| `Recorder/MovieRecorder.{h,m}` | + `startTime`: the take's clock |
| `Recorder/Take.{h,m}` | the movies of one recording: names, clock, per-movie state |
| `Recorder/RecorderController.{h,m}` | places, connections to ticked sources, the parameter table |
| `App/SimpleRecorderApp.swift` | `@main`, window, menu, quit and SIGTERM |
| `App/SyphonSources.swift` | `SyphonSource`, `SyphonDirectory` (the only file which imports Syphon) |
| `App/RecorderModel.swift` | observable model over `RecorderController` (KVO → SwiftUI) |
| `App/Theme.swift` | OSCScore's palette and fonts |
| `App/Views/{TakeBar,SourcesSidebar,MonitorView,TextureView,InspectorView,StatusBar,ContentView}.swift` | the window's zones |
| `App/SettingsMigration.swift` | copies the recorder's settings from `net.am-cb.simple-client` once |
| `Resources/Info.plist`, `Resources/icon.icns` | the bundle's |
| `Tests/RecorderKitTests/*` | core tests (existing, extended) |
| `Tests/SimpleRecorderTests/*` | model, migration, views rendered off screen |
| `MCP/main.swift` | places, new name |
| `Simple Server/` | + `-ServerName <name>`, to run several which can be told apart |
| removed | `Simple Client/`, its Xcode project, `Tools/settings-test.m`, `Tools/view-test.m` if nothing else uses them; `Simple.xcworkspace` keeps Simple Server |

---

### Task 1: SwiftPM app, bundle, rename

**Files:** Create `Scripts/syphon.sh`, `App/SimpleRecorderApp.swift` (a window titled "Simple Recorder" with a placeholder text), `Resources/Info.plist`, `Tests/SimpleRecorderTests/SmokeTests.swift`. Modify `Package.swift`, `Scripts/bundle.sh`, `.gitignore`, `.mcp.json`, `Simple Server/Simple_ServerAppDelegate.m` (`-ServerName`).

**Interfaces — Produces:** `swift build`, `swift test` (after `Scripts/syphon.sh`); `Scripts/bundle.sh` → `build/Simple Recorder.app` (signed, `Contents/Frameworks/Syphon.framework`, `Contents/MacOS/simple-recorder-mcp`, rpath `@executable_path/../Frameworks`), `build/Simple Server.app`.

- [ ] **Step 1:** `Scripts/syphon.sh`: `xcodebuild` Release, generic macOS → `xcodebuild -create-xcframework` → `build/Syphon.xcframework`; does nothing when the xcframework is newer than the submodule's HEAD.
- [ ] **Step 2:** `Package.swift` as proved; `swift-tools-version: 5.9`, `.macOS(.v14)`.
- [ ] **Step 3:** test `testTheAppTargetSeesTheCoreAndSyphon` (creates a `FramePacer`, reads `SyphonServerDirectory.shared().servers`); `swift test` → passes with the existing 78.
- [ ] **Step 4:** `Info.plist` (name, identifier, version 6, `NSLocalNetworkUsageDescription`, `NSBonjourServices`, `LSMinimumSystemVersion` 14.0, `NSHighResolutionCapable`); `bundle.sh` assembles the bundle from `.build/apple/Products/Release`, adds the rpath with `install_name_tool`, signs framework, tool, app.
- [ ] **Step 5:** Simple Server: `-ServerName` → the Syphon server's name (title "name - Simple Server"); built by `bundle.sh` as today.
- [ ] **Step 6:** run `build/Simple Recorder.app/Contents/MacOS/Simple Recorder` for 3 s: alive, no `dyld` error; `codesign --verify --deep --strict`; `lipo -archs` → `x86_64 arm64`.
- [ ] **Step 7:** commit "Build Simple Recorder with SwiftPM: SwiftUI app, Syphon as an xcframework".

### Task 2: A clock given to the recorder

**Files:** Modify `Recorder/FramePacer.{h,m}`, `Recorder/MovieRecorder.{h,m}`, their tests.

**Interfaces — Produces:**

```objc
// FramePacer: origin is the time which is 0 in the movie; NAN makes the first frame the origin, as before.
- (instancetype)initWithFramesPerSecond:(double)framesPerSecond origin:(double)origin;

// MovieRecorder: startTime is the take's time zero on the clock of appendTexture:…atTime:; NAN for the first frame.
- (BOOL)startWritingToURL:(NSURL *)url settings:(MovieRecorderSettings *)settings startTime:(NSTimeInterval)startTime error:(NSError **)error;
```

The existing initialisers call these with `NAN`.

- [ ] **Step 1:** tests — pacer: `testAnOriginPlacesTheFirstFrameWhereItArrived` (origin 100, arrival 100.5, no cap → time 0.5; cap 30 → slot 15, time 0.5), `testAFrameBeforeTheOriginIsDiscarded`. Recorder: `testAStartTimePlacesTheFirstFrameOnTheClock` (start time 100, 30 frames from 101.0 to 101.97, finish at 102 → duration 2.0 ± 0.05, first sample's presentation time 1.0 ± 0.02, 30 samples).
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Let a recorder take its time zero from outside".

### Task 3: Take

**Files:** Create `Recorder/Take.{h,m}`, `Tests/RecorderKitTests/TakeTests.swift`; add to `Recorder/RecorderKit.h`.

**Interfaces — Consumes** `MovieRecorder` (Task 2). **Produces:**

```objc
// One movie of a take
@interface TakeMovie : NSObject
@property (readonly, copy) NSString *sourceTitle;
@property (readonly) NSURL *url;
@property (readonly) NSUInteger framesWritten;
@property (readonly) NSUInteger framesDropped;
// Why this movie stopped before the take did, nil otherwise
@property (readonly, nullable) NSError *error;
@end

@interface Take : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
// The names a take would give its movies: "<name>.mov" for one source, "<name> — <title>.mov" for several.
// None exists: if one did, the same number is added to all ("<name> 2 — <title>.mov").
+ (NSArray<NSURL *> *)urlsForName:(NSString *)name sourceTitles:(NSArray<NSString *> *)titles inFolder:(NSURL *)folder;
// sizes: the size of each source's frames if known (NSValue of NSSize), NSNull if not.
- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles
                        sizes:(NSArray *)sizes
                         name:(NSString *)name
                       folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings
                       atTime:(NSTimeInterval)time
                        error:(NSError **)error;
// Any thread
- (void)appendTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped fromSourceAtIndex:(NSUInteger)index atTime:(NSTimeInterval)time;
// handler on the main queue: an error if no movie has frames; the movies' own errors are in movies.
- (void)finishAtTime:(NSTimeInterval)time completionHandler:(void (^)(NSError * _Nullable error))handler;
@property (readonly, getter=isRecording) BOOL recording;
@property (readonly) NSArray<TakeMovie *> *movies;
// Main queue, when a movie fails while the others go on
@property (copy, nullable) void (^movieFailureHandler)(NSUInteger index, NSError *error);
@end
```

Names are made safe as today (`/` and `:` replaced, no leading dot), for the name and for each title. Settings: `width`/`height` are ignored for separate movies (each at its source's size).

- [ ] **Step 1:** tests: `testOneSourceTakesTheNameAlone`; `testSeveralSourcesAreNamedAfterTheirTitles`; `testTheSameNumberIsAddedToEveryNameWhenOneExists`; `testTitlesCannotLeaveTheFolder`; `testTwoMoviesShareTheTakesClock` (source B's first frame 0.5 s after A's → B's first sample at 0.5 s later than A's, both durations equal to the take's); `testAMovieWhichStartsLateIsPlacedOnTheTakesClock`; `testASourceWhichNeverArrivesLeavesNoFileAndIsNotAFailure`; `testATakeWithNoFrameAtAllFails`; `testStartFailsInAMissingFolderAndWritesNothing`; `testStartWhileRecordingOrFinishingFails`; `testFramesAndDropsAreCountedPerMovie`.
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Add Take: the movies of one recording, on one clock".

### Task 4: Places in RecorderController

**Files:** Create `Recorder/FrameSource.h`. Rewrite the source part of `Recorder/RecorderController.{h,m}`; `Tests/RecorderKitTests/RecorderControllerTests.swift` (fakes: `FakeDirectory`, `FakeSource` delivering textures on demand).

**Interfaces — Consumes** `Take`. **Produces:**

```objc
typedef NS_ENUM(NSInteger, FrameSourceKind) { FrameSourceKindSyphon, FrameSourceKindNDI };

@interface SourceDescription : NSObject
@property (readonly, copy) NSString *title;      // as shown, and as used in OSC
@property (readonly, copy) NSString *detail;     // the application, or "NDI"
@property (readonly) FrameSourceKind kind;
- (instancetype)initWithTitle:(NSString *)title detail:(NSString *)detail kind:(FrameSourceKind)kind;
@end

@protocol FrameSource <NSObject>
@property (readonly, copy) NSString *title;
// YES if the first row of its textures is the bottom of the picture
@property (readonly) BOOL flipped;
// Called for every frame, on any thread
@property (copy, nullable) void (^frameHandler)(id<MTLTexture> frame);
- (void)stop;
@end

@protocol SourceDirectory <NSObject>
// Main thread. What can be recorded now.
- (NSArray<SourceDescription *> *)availableSources;
// Connects to the source with this title; nil if it is not there
- (nullable id<FrameSource>)connectToSourceWithTitle:(NSString *)title device:(id<MTLDevice>)device;
// Called on the main queue when availableSources changes
@property (copy, nullable) void (^changeHandler)(void);
@end

// The state of one place, KVO-compliant, refreshed four times a second
@interface RecorderPlace : NSObject
@property (readonly, copy) NSString *title;
@property (readonly, getter=isOnline) BOOL online;
@property (readonly) NSInteger width, height;
@property (readonly) double fps;
@property (readonly, copy) NSString *file;       // its movie in this take or the last, "" if none
@property (readonly) NSUInteger frames, dropped;
@property (readonly, nullable) id<MTLTexture> latestFrame;   // for the monitor
@property (readonly) BOOL flipped;
@end

// RecorderController: replaces sourceProvider and the single-source API
- (instancetype)initWithDevice:(id<MTLDevice>)device directory:(id<SourceDirectory>)directory defaults:(NSUserDefaults *)defaults;
@property (readonly, copy) NSArray<RecorderPlace *> *places;                 // the ticked sources, in order (0…8)
@property (readonly, copy) NSArray<SourceDescription *> *availableSources;   // KVO
- (BOOL)addSourceMatching:(NSString *)title;                    // at the end; exact title, then a part of it
- (BOOL)setSourceMatching:(NSString *)title atPlace:(NSUInteger)place;  // 1-based; "" removes; places close up
- (void)removeSourceAtPlace:(NSUInteger)place;
- (BOOL)moveSourceFromPlace:(NSUInteger)from toPlace:(NSUInteger)to;
```

All four return NO with `error` set while a take is recording or finishing, when there are already 8 places, or when no source matches. Removed: `RecorderSourceProvider`, `selectSourceMatching:`, `sourcesDidChange`, `sourceSelectionDidChange:`, `frameReceived:`, `sourceWidth/Height/FPS`. `frames`, `dropped`, `file` become what the spec's table says. Places are saved in the defaults (titles, in order) and reconnected at launch and whenever the directory changes.

Parameter table: `/source/1`…`/source/8` and `/source` (alias of 1), `/status/source/N/{online,width,height,fps,file,frames,dropped}`; the rest unchanged. `/output`, `/layout`, `/gap`, `/width`, `/height`, `/sound`, `/status/assembled/…`, `/status/ndi` belong to later parts: `/width` and `/height` stay registered and saved, without effect on separate movies.

- [ ] **Step 1:** tests (the existing ones adapted to the fakes, plus): `testTickingConnectsAndUntickingDisconnects`; `testOnlyTickedSourcesAreConnected`; `testASourceIsInOnePlaceOnly`; `testPlacesCloseUp`; `testNoMoreThanEightPlaces`; `testPlacesCannotChangeWhileRecording`; `testPlacesPersistAndReconnect`; `testASourceWhichComesBackGoesOnInItsPlace` (directory loses it: place stays, offline; returns: reconnected, frames reach its movie again); `testSourceIsAnAliasOfTheFirstPlace`; `testOSCSetsAndClearsAPlace`; `testOSCQueryDescribesThePlaces` (8 `/source/N` with `VALS`, `/status/source/N/…`); `testRecordingWritesOneMoviePerPlace` (three fakes → three files, right sizes); `testStartWithoutAPlaceFails`; `testTheMonitorGetsEachPlacesLatestFrame`.
- [ ] **Step 2–4:** fail, implement, pass; whole suite green. **Step 5:** commit "Places: several sources ticked, one movie each".

### Task 5: Syphon sources

**Files:** Create `App/SyphonSources.swift`, `Tests/SimpleRecorderTests/SyphonSourcesTests.swift`.

**Interfaces — Produces:** `final class SyphonDirectory: NSObject, SourceDirectory` (titles as `ServerDescriptionValueTransformer` made them: `name - application`, or whichever exists, "Untitled Server"; observes `SyphonServerDirectory`'s announce, update and retire notifications); `final class SyphonSource: NSObject, FrameSource` over `SyphonMetalClient` (`flipped` YES).

- [ ] **Step 1:** tests on the pure part: `testTitlesAreNameThenApplication` (the four cases, from description dictionaries). With servers: `testReceivesFramesFromASyphonServer`, which publishes from an in-process `SyphonMetalServer` and is skipped if none can be made.
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Syphon servers as sources".

### Task 6: The window

**Files:** Create `App/Theme.swift`, `App/RecorderModel.swift`, `App/Views/*.swift`, `Tests/SimpleRecorderTests/{RecorderModelTests,ViewRenderingTests}.swift`. Modify `App/SimpleRecorderApp.swift`.

**Interfaces — Produces:** `@MainActor final class RecorderModel: ObservableObject` — published mirrors of the controller (state, elapsed, frames, dropped, error, failure, places, available sources, settings, ports) kept by KVO, and actions (`toggleRecording()`, `tick(_:)`, `untick(place:)`, `move(from:to:)`, setters). `ContentView(model:)` is the whole window: `TakeBar` (record button pressed with a stop square while recording, time large, frames and drops), `SourcesSidebar` (ticked first, in order, draggable; then available; dimmed when offline; disabled while recording), `MonitorView` (the ticked sources in a grid, each a `TextureView` with its title; an invitation when none is ticked), `InspectorView` (Movie: codec, frame rate, bitrate; Files: folder, name), `StatusBar` (ports, free space, number of movies, the error or failure). ⌘R and File ▸ Start/Stop Recording; quitting and SIGTERM finish the take (the rule of D26, including not calling `terminate` from a main-queue block).

- [ ] **Step 1:** model tests with the fakes of Task 4: `testTheModelFollowsTheController` (an OSC message changes a published value), `testTickingFromTheModelReachesTheController`, `testStartedByOSCTheModelSaysRecording`, `testAnErrorIsPublishedThenClearedAfterSixSeconds` (the delay injected), `testAFailureStaysUntilTheNextTake`.
- [ ] **Step 2:** view tests: render `ContentView` at 1100 × 680 with `NSHostingView` + `cacheDisplay` for four states — nothing ticked, three ticked idle, recording, a failure — to `build/views/*.png`; assert the bitmaps are not blank and differ between states; **read the four pictures** and compare with the mock-up.
- [ ] **Step 3–4:** implement until green and the pictures are right. **Step 5:** commit "The Simple Recorder window".

### Task 7: MCP, migration, clearing out Simple Client

**Files:** Modify `MCP/main.swift`, `Tools/build.sh`, `Tools/*`, `README.md`, `Simple.xcworkspace`. Create `App/SettingsMigration.swift`. Remove `Simple Client/`, `Tools/settings-test.m`.

- [ ] **Step 1:** migration test `testSettingsAreMigratedOnce` (two `UserDefaults` suites: the `Recorder*` keys are copied, a marker is set, a second run copies nothing even if the old ones changed) → fail → implement → pass.
- [ ] **Step 2:** MCP: application name "Simple Recorder"; `recorder_status` returns `places` (title, online, size, fps, file, frames, dropped) and `sourcesAvailable` with their kind; `recorder_configure`/`recorder_start` take `sources: [titles]` (replaces the places, in order) and still `source` (the first place).
- [ ] **Step 3:** remove Simple Client's project and sources; the workspace keeps Simple Server; `Tools/build.sh` keeps `syphon-probe`, `gl-server`, `movie-info`.
- [ ] **Step 4:** `swift test`, `Scripts/bundle.sh`, `Tools/build.sh` all pass. **Step 5:** commit "MCP for places; settings carried over; Simple Client removed".

### Task 8: End to end, documentation, review

- [ ] **Step 1:** signed bundle on test ports, three Simple Servers (`-ServerName A`, `B`, `C`, windows of different sizes): tick A and B by OSC (`/source/1`, `/source/2`), record 5 s at 30 fps, stop → two movies, right sizes, 30.00 fps, equal durations; read a frame of each back.
- [ ] **Step 2:** take clock: tick C with its server not running, start, launch C after 2 s, stop at 5 s → C's movie starts 2 s in (`movie-info` extended to print the first sample's time).
- [ ] **Step 3:** quit C's server mid-take and relaunch → C's place offline then online, its movie goes on; `kill -TERM` during a take → all movies finished; `/source "x"`, `/record 1/0` as OSCScore sends them → works; eight servers at 1080p for 20 s → movies, drops and CPU noted.
- [ ] **Step 4:** MCP over stdio: `recorder_configure {sources:[…]}`, `recorder_start`, `recorder_stop`, `recorder_status`.
- [ ] **Step 5:** README (window, places, addresses), `DECISIONS.md` (D35…: SwiftUI and SwiftPM, places, one clock, names, places locked during a take), `CLAUDE.md` (build, `Scripts/syphon.sh` first, test recipes).
- [ ] **Step 6:** whole-branch review by a fresh reviewer; one fix pass; commit; push.
