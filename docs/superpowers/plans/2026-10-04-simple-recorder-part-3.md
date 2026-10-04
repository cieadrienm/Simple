# Simple Recorder, part 3: NDI pictures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** NDI sources appear in the list beside the Syphon servers, and are ticked, placed, shown, assembled and recorded exactly as they are; without NDI's library the app runs and says "NDI off".

**Architecture:** NDI is reached through its SDK's library, `libndi.dylib`, loaded with `dlopen` when the app starts (`NDILibrary`), never linked. Three pieces sit on it in the Objective-C core: `NDIFinder` (the sources on the network), `NDISource` (a `FrameSource`: a receiver and a thread which copies each BGRA frame into a Metal texture taken from a small ring, `NDITextureRing`), `NDIDirectory` (a `SourceDirectory`). `CompositeDirectory` puts Syphon's directory and NDI's into the one directory `RecorderController` already takes, so that nothing downstream — places, takes, the compositor — knows where a frame comes from, except that an NDI frame is not flipped.

**Tech Stack:** as parts 1–2 — Objective-C core (`Recorder/`), SwiftUI window (`App/`), Metal, AVFoundation, SwiftPM, XCTest — plus the NDI SDK 6 headers (MIT) and `dlopen`.

**Spec:** `docs/superpowers/specs/2026-10-03-simple-recorder-design.md` — "Sources", the NDI lines of "Decisions made for him", `/status/ndi` in "Parameters", "MCP" (the kind of each source), "Structure", "Errors" (NDI missing is a state), "Tests" (NDI against the SDK's own sender, skipped without the library). **Sound is part 4**: this part receives and discards NDI audio.

## Global Constraints

- Everything parts 1–2 established stands (`DECISIONS.md` D35–D55, `CLAUDE.md`): macOS 14, places locked while recording, one clock per take, the take's picture decided at its start, 16384 on a side, a picture handed on only once drawn, the test and end-to-end recipes.
- **`Recorder/` never imports Syphon, and never links NDI**: the library is found and loaded at run time. If `SIMPLE_NDI_LIBRARY` is set, that path alone is tried (tests; running without NDI). Otherwise, in this order: `Contents/Frameworks/libndi.dylib` of the app; `$NDI_RUNTIME_DIR_V6/libndi.dylib`; `/usr/local/lib/libndi.dylib`; `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib`.
- The SDK's headers (MIT, their notice kept) are in the repository under `ThirdParty/NDI/include`; **the library is not**. `Scripts/bundle.sh` copies it into the app when the SDK is installed, and builds a working app when it is not.
- NDI missing is a state, not an error: `/status/ndi` is 0, the status bar says "NDI off", no error is set, every test which needs the library is skipped (`XCTSkip`) rather than failed.
- A source is known by its title: the NDI name as the finder gives it (`MACHINE (Name)`). Its detail is `NDI`, its kind `FrameSourceKindNDI`. A Syphon server and an NDI source with the same title: the Syphon one is taken (the first, as today).
- An NDI frame is received as BGRA (`NDIlib_recv_color_format_BGRX_BGRA`), progressive (`allow_video_fields` false), at the highest bandwidth; its first row is the top: `flipped` is NO. A frame without alpha (`BGRX`) is opaque.
- A frame's time is its arrival (`CACurrentMediaTime()` in the controller), as for Syphon: NDI's own timestamps are not used.
- Only ticked sources are connected to: a receiver exists only for a place.
- Every new behaviour has a test which failed first. Commits in English with the harness's `Co-Authored-By` line. Work on a branch `ndi`, pushed to `origin`; merged into `master` at the end with Adrien's say.
- End-to-end runs use test ports and `-RecorderFolder`; Adrien's preferences are exported before and re-imported after (and keys added by the run removed). His apps are never killed.

## Review Focus

1. **The library is absent, or is not NDI's**: the app runs, `/status/ndi` is 0, the status bar says "NDI off", no NDI source is listed, nothing is reported as an error — Task 1, `testALibraryWhichIsNotThereIsNotAvailable`, `testAFileWhichIsNotTheLibraryIsNotAvailable`; Task 5, `testNDIOffIsAStateNotAnError`.
2. **The sender quits during a take, and comes back**: its place is black once it is known gone, alive again when it is back, the movie whole — Task 4, `testASourceWhoseSenderHasGoneIsNotAlive`; Task 8, end to end.
3. **The sender changes its size while it is received**: the next textures have the new size; nothing is read out of bounds — Task 2, `testASizeChangeMakesNewTextures`; Task 4, `testASenderWhichChangesSizeIsFollowed`.
4. **The first row is the top**: an NDI picture is upright in a source's movie and in the assembled one, beside a Syphon picture which is flipped — Task 4, `testThePictureIsUpright`; Task 8, frames read back.
5. **A frame is still waiting to be encoded when the next ones arrive**: its texture is not written over (three frames at most wait in a recorder, one is kept by the place, one is being composed) — Task 2, `testATextureIsNotWrittenOverByTheFramesWhichFollow`.
6. **A row is longer than the picture is wide** (`line_stride_in_bytes` > width × 4): the picture is not sheared — Task 2, `testRowsLongerThanThePictureAreCopiedRight`.
7. **No alpha (`BGRX`)**: the picture is opaque in a ProRes 4444 movie, whatever its fourth byte holds — Task 2, `testAPictureWithoutAlphaIsOpaque`.
8. **A source is unticked, or the app quits, while frames arrive**: no frame is delivered after `stop` returns, the thread ends, nothing is leaked or crashes — Task 4, `testNoFrameIsDeliveredAfterStop`.
9. **The same title in Syphon and in NDI**: one entry in the list, the Syphon one connected — Task 5, `testASyphonServerComesBeforeAnNDISourceOfTheSameTitle`.

## File Structure

| File | Responsibility |
|---|---|
| `ThirdParty/NDI/include/*.h`, `ThirdParty/NDI/README.md` | the SDK's headers, unchanged; where they come from, their licence, the version |
| `Recorder/NDILibrary.{h,m}` | finds and loads `libndi.dylib`; the SDK's table of functions; whether NDI is available |
| `Recorder/NDITextureRing.{h,m}` | a frame's bytes → a Metal texture, from a ring which is not written over too soon (no NDI in it: pure Metal) |
| `Recorder/NDIFinder.{h,m}` | the NDI sources on the network, and a call when they change |
| `Recorder/NDISource.{h,m}` | a `FrameSource`: a receiver, its thread, its frames as textures |
| `Recorder/NDIDirectory.{h,m}` | a `SourceDirectory` over the finder |
| `Recorder/CompositeDirectory.{h,m}` | several directories as one |
| `Recorder/RecorderController.{h,m}` | + `ndiAvailable`, a place's kind, `/status/ndi`, `/status/ndi/sources`, `/status/source/N/kind` |
| `App/SimpleRecorderApp.swift` | makes the two directories and the composite |
| `App/RecorderModel.swift`, `App/Views/{SourcesSidebar,StatusBar}.swift` | a source's kind in the list; "NDI on" / "NDI off" |
| `Resources/Info.plist`, `Scripts/bundle.sh` | `_ndi._tcp` among the Bonjour services; the library copied into the app and signed |
| `MCP/main.swift` | the kind of each source, chosen and available; `ndi` in the status |
| `Tools/ndi-send.m`, `Tools/build.sh` | an NDI sender of the test pattern, for end-to-end runs |
| `Tests/RecorderKitTests/{NDILibrary,NDITextureRing,NDIFinder,NDISource,CompositeDirectory}Tests.swift` | |
| `Tests/NDITestSupport/NDITestSender.{h,m}` | an NDI sender for the tests, in a target of its own: not in the product |

---

### Task 1: The headers, the library, and proof that a frame crosses

The part's one unknown is here: that SwiftPM takes the headers from `ThirdParty/`, that the library loads from a test and from the signed app, and that a frame sent in a process is found and received by it. Nothing else is built until this is green.

**Files:** Create `ThirdParty/NDI/include/` (copied from `/Library/NDI SDK for Apple/include`), `ThirdParty/NDI/README.md`, `Recorder/NDILibrary.{h,m}`, `Tests/RecorderKitTests/NDILibraryTests.swift`, `Tests/NDITestSupport/NDITestSender.{h,m}`; modify `Package.swift`, `Recorder/RecorderKit.h`.

**Interfaces — Produces:**

```objc
// NDILibrary.h — does NOT include the SDK's headers: RecorderKit's users (Swift) never see them
@interface NDILibrary : NSObject
// The library found in the places listed in the Global Constraints, loaded once. Never nil: see available.
+ (NDILibrary *)sharedLibrary;
// A library at a path, for tests. Never nil.
- (instancetype)initWithPath:(nullable NSString *)path;
@property (readonly, getter=isAvailable) BOOL available;
// "NDI SDK APPLE 6.1.1" or such; empty if it is not available
@property (readonly, copy) NSString *version;
// Where it was loaded from; nil if it is not available
@property (readonly, nullable, copy) NSString *path;
// Why it is not available ("libndi.dylib was not found", "… is not an NDI library", "this Mac cannot run NDI")
@property (readonly, copy) NSString *reason;
@end
```

```objc
// NDILibrary+Functions.h — private to Recorder/ (not in RecorderKit.h); includes Processing.NDI.Lib.h
@interface NDILibrary (Functions)
// The SDK's table (NDIlib_v5_load), NULL if not available. initialize() has been called.
@property (readonly, nullable) const NDIlib_v5 *functions;
@end
```

`Package.swift`: `RecorderKit` gains `cSettings: [.headerSearchPath("../ThirdParty/NDI/include")]`. If SwiftPM refuses a path outside the target, the headers go to `Recorder/NDI/include` instead (not named in `RecorderKit.h`, so not part of the module), and the ruling is ledgered. The library is loaded with `dlopen(path, RTLD_NOW | RTLD_LOCAL)`, `NDIlib_v5_load` found with `dlsym`, `initialize()` called once; `destroy()` is never called (the library lives as long as the process).

`NDITestSender` (test support, not in the product): a target of its own, `NDITestSupport` (`Tests/NDITestSupport/NDITestSender.{h,m}`, Objective-C, depending on `RecorderKit`, with header search paths to `ThirdParty/NDI/include` and `Recorder/` for `NDILibrary+Functions.h`), which the two test targets depend on.

```objc
// A sender made through the library, under a name of its own, which sends a picture at a rate on its own thread
@interface NDITestSender : NSObject
// nil if the library is not available: the test is then skipped (XCTSkip), not failed
- (nullable instancetype)initWithLibrary:(NDILibrary *)library name:(NSString *)name;
// The picture sent from now on: one colour (blue, green, red, alpha), an orange top left quarter if marked.
// hasAlpha NO sends BGRX, with alpha as the fourth byte all the same. padding: bytes added to each row.
- (void)sendWidth:(int)width height:(int)height colour:(const uint8_t *)bgra marked:(BOOL)marked
         hasAlpha:(BOOL)hasAlpha padding:(int)padding framesPerSecond:(int)framesPerSecond;
- (void)stop;
@end
```

- [ ] **Step 1:** copy the headers; write `ThirdParty/NDI/README.md` (source, version `6.1.1`, MIT notice applies to the headers only, the library is under the SDK's licence and is not in the repository, "NDI® is a registered trademark of Vizrt NDI AB").
- [ ] **Step 2:** tests, in `NDILibraryTests`: `testTheSDKsLibraryLoads` (skipped if `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib` is not there: available, version begins with "NDI", path is the one given); `testALibraryWhichIsNotThereIsNotAvailable` (a path which does not exist: not available, version empty, reason names the path); `testAFileWhichIsNotTheLibraryIsNotAvailable` (the path of `/usr/lib/libz.dylib`: not available, reason says it is not an NDI library; no crash); `testTheEnvironmentChoosesTheLibrary` (through a class method `+candidatePathsWithEnvironment:bundlePath:`, which is pure: `SIMPLE_NDI_LIBRARY` alone when set, otherwise the four places in order); `testAFrameSentIsReceived` (a `NDITestSender`, and `+[NDITestSender receiveOneFrameNamed:library:timeout:]`, a raw `find` + `recv` through the function table which returns the frame's size: within 15 s a video frame of the sender's size arrives — **the proof**).
- [ ] **Step 3:** run: they fail to compile. **Step 4:** implement. **Step 5:** run: `swift test --filter NDILibraryTests` green; whole suite green.
- [ ] **Step 6:** if `testAFrameSentIsReceived` cannot pass on this Mac (discovery blocked for an unsigned test runner), stop and ledger what was seen: the fallback is to connect the receiver to the sender's address directly (`url_address` `127.0.0.1:<port>`), and to prove discovery in Task 8 on the signed app. Do not go on without one of the two.
- [ ] **Step 7:** commit "Load NDI's library at run time".

### Task 2: A frame's bytes as a texture

**Files:** Create `Recorder/NDITextureRing.{h,m}`, `Tests/RecorderKitTests/NDITextureRingTests.swift`; add to `Recorder/RecorderKit.h`.

**Interfaces — Produces:**

```objc
/*
 Copies pictures given as bytes into Metal textures. The textures come from a ring: one returned is not written
 to again by the five calls which follow, so that it can wait to be shown, composed and encoded.
 */
@interface NDITextureRing : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
// bytes: BGRA, the first row at the top, rows of bytesPerRow bytes (at least width × 4).
// hasAlpha NO: the fourth byte of each pixel is not alpha; the texture returned reads as opaque.
// nil if width or height is 0 or above 16384, or bytesPerRow is too short. One thread at a time.
- (nullable id<MTLTexture>)textureWithBytes:(const void *)bytes
                                      width:(NSUInteger)width
                                     height:(NSUInteger)height
                                bytesPerRow:(NSUInteger)bytesPerRow
                                   hasAlpha:(BOOL)hasAlpha;
@end
```

Six textures (`MTLPixelFormatBGRA8Unorm`, shared storage, shader read), remade when the size changes. Without alpha the texture returned is a view of the ring's texture whose alpha is swizzled to one (`newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:`), made once for each texture of the ring.

- [ ] **Step 1:** tests (pixels read back with `getBytes`): `testThePictureIsCopiedAsItIs` (four corners of four colours); `testRowsLongerThanThePictureAreCopiedRight` (bytesPerRow = width × 4 + 64, the padding filled with white: no white in the texture, the last row right); `testAPictureWithoutAlphaIsOpaque` (fourth bytes 0 and 37: the texture, drawn by `Compositor` with `transparent: true`, has alpha 255 where the picture is); `testAPictureWithAlphaKeepsIt`; `testATextureIsNotWrittenOverByTheFramesWhichFollow` (a red picture, then five others: the first texture is still red; the seventh call may reuse it); `testASizeChangeMakesNewTextures` (640 × 360 then 320 × 180: the second texture is 320 × 180, the first still 640 × 360 and unchanged); `testSizesWhichCannotBeAreRefused` (0, 20000, a bytesPerRow shorter than the width).
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Add NDITextureRing: a frame's bytes as a texture".

### Task 3: The sources on the network

**Files:** Create `Recorder/NDIFinder.{h,m}`, `Recorder/NDIDirectory.{h,m}`, `Tests/RecorderKitTests/NDIFinderTests.swift`; add `NDIDirectory.h` to `Recorder/RecorderKit.h` (the finder stays private to `Recorder/`).

**Interfaces — Consumes** Task 1. **Produces:**

```objc
// NDIFinder.h (private: includes the SDK's headers)
@interface NDIFinder : NSObject
// nil if the library is not available
- (nullable instancetype)initWithLibrary:(NDILibrary *)library;
// The names of the sources found, in the order found. Any thread.
@property (readonly, copy) NSArray<NSString *> *sourceNames;
// The SDK's description of a source, to connect to it; NO if it is not (or no longer) found
- (BOOL)getSource:(NDIlib_source_t *)source named:(NSString *)name;
// Called on the main queue when sourceNames has changed
@property (copy, nullable) void (^changeHandler)(void);
- (void)stop;
@end

// NDIDirectory.h (public)
@interface NDIDirectory : NSObject <SourceDirectory>
// Lists nothing, and connects to nothing, if the library is not available
- (instancetype)initWithLibrary:(NDILibrary *)library;
@end
```

The finder has a thread which waits on `find_wait_for_sources` (1 s) and reads `find_get_current_sources`; the names and the strings they point to are copied at once (the SDK's pointers live until the next call). `show_local_sources` is YES: an NDI sender on this Mac is a source. `NDIDirectory` gives each name as a `SourceDescription` (detail `NDI`, kind NDI); `connectToSourceWithTitle:device:` returns nil until Task 4.

- [ ] **Step 1:** tests (each skipped without the library; each waits up to 15 s on a condition, never a fixed sleep): `testASenderIsFound` (its name ends with `(Test <uuid>)`); `testASenderWhichStopsIsNoLongerFound`; `testTheChangeHandlerIsCalledOnTheMainQueue`; `testTheDirectoryListsNDISourcesAsNDI` (title, detail `NDI`, kind); `testWithoutTheLibraryTheDirectoryIsEmpty` (a library at a path which does not exist: no source, no crash, `connect` nil); `testStopEndsTheThread` (no call after `stop`).
- [ ] **Step 2–4:** fail, implement, pass. **Step 5:** commit "Find the NDI sources on the network".

### Task 4: An NDI source delivers frames

**Files:** Create `Recorder/NDISource.{h,m}`, `Tests/RecorderKitTests/NDISourceTests.swift`; modify `Recorder/NDIDirectory.m`.

**Interfaces — Consumes** Tasks 1–3. **Produces:**

```objc
// NDISource.h (private: made by NDIDirectory)
@interface NDISource : NSObject <FrameSource>
// Connects to a source the finder has found. nil if the receiver cannot be made.
- (nullable instancetype)initWithTitle:(NSString *)title
                                source:(const NDIlib_source_t *)source
                               library:(NDILibrary *)library
                                device:(id<MTLDevice>)device;
@end
```

`flipped` is NO. The receiver is made with `color_format = NDIlib_recv_color_format_BGRX_BGRA`, `bandwidth = NDIlib_recv_bandwidth_highest`, `allow_video_fields = false`, and a receiver name `Simple Recorder`. A thread loops on `recv_capture_v3` (timeout 100 ms): a video frame goes through the `NDITextureRing` (`hasAlpha` from its FourCC: `BGRA` yes, `BGRX` no; any other FourCC is dropped and counted in a log line once) and to `frameHandler`, then is freed; audio and metadata frames are freed at once (**sound is part 4**). `stop` asks the thread to end, waits for it (it never waits more than the timeout), then destroys the receiver: no frame is delivered after it returns. `alive` is `recv_get_no_connections(…) > 0`, or YES during the first three seconds after the source was made (a connection takes a moment) — a sender which has quit is not alive, the controller lets the source go and asks the directory again, as it does for Syphon (D42).

- [ ] **Step 1:** tests (skipped without the library; a `NDITestSender` each): `testFramesArriveAtTheSendersSize`; `testThePictureIsUpright` (the sender's orange quarter is at the texture's top left, read back; `flipped` is false); `testAPictureSentWithoutAlphaIsOpaque` (BGRX with a fourth byte of 0); `testASenderWhichChangesSizeIsFollowed`; `testASourceWhoseSenderHasGoneIsNotAlive` (alive while frames arrive; the sender stops: not alive within 10 s); `testNoFrameIsDeliveredAfterStop` (a handler which counts; `stop`; the count does not move in the following second; the source deallocates — a weak reference is nil); `testTheDirectoryConnects` (`NDIDirectory.connectToSource(withTitle:)` returns a source which delivers; an unknown title returns nil); `testAnNDISourceIsRecorded` (a `RecorderController` over an `NDIDirectory`: the sender ticked, a one-second take, the movie is the sender's size and its first picture has the orange quarter at its top left).
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "Receive an NDI source as textures".

### Task 5: One directory, and the kind of each source

**Files:** Create `Recorder/CompositeDirectory.{h,m}`, `Tests/RecorderKitTests/CompositeDirectoryTests.swift`; modify `Recorder/RecorderController.{h,m}`, `Recorder/RecorderKit.h`, `Tests/RecorderKitTests/RecorderControllerTests.swift`.

**Interfaces — Produces:**

```objc
// CompositeDirectory.h
@interface CompositeDirectory : NSObject <SourceDirectory>
// The directories, in order: of sources with the same title, the first directory's is the one
- (instancetype)initWithDirectories:(NSArray<id<SourceDirectory>> *)directories;
@end

// RecorderPlace
@property (readonly) FrameSourceKind kind;        // of the source it is connected to, or was last
@property (readonly, copy) NSString *kindName;    // "syphon", "ndi"; empty for a place never connected

// RecorderController
@property (nonatomic, assign) BOOL ndiAvailable;  // /status/ndi: set by the app from the library; NO by default
```

`FrameSource` gains nothing: a place learns its kind from the `SourceDescription` of its title (the first in `availableSources`), when it connects. New parameters, all read-only: `/status/ndi` (i: 1 if NDI is available), `/status/ndi/sources` (s: the titles of the NDI sources available, one per line — what tells a client the kind of an available source), `/status/source/N/kind` (s). `CompositeDirectory.availableSources` is the directories' sources one after the other; `connectToSourceWithTitle:` asks each directory which lists the title, in order, and returns the first source made; its `changeHandler` is called when any directory's is.

- [ ] **Step 1:** tests with fake directories (the `FakeDirectory` of the controller's tests gains a `kind`): `testSourcesOfAllDirectoriesAreListedInOrder`; `testASyphonServerComesBeforeAnNDISourceOfTheSameTitle` (listed once by the controller, connected through the first directory); `testTheSecondDirectoryConnectsWhenTheFirstDoesNotListTheTitle`; `testAChangeInAnyDirectoryIsTold`; `testAPlaceKnowsItsKind` (and keeps it when its source goes away); `testNDIOffIsAStateNotAnError` (`ndiAvailable` NO: `/status/ndi` 0, `error` empty, `errorCount` 0); `testOSCQueryDescribesNDI` (`/status/ndi`, `/status/ndi/sources` with two fake NDI titles on two lines, `/status/source/1/kind`); `testAnNDIPlaceIsNotFlippedInTheAssembledPicture` (a fake NDI source beside a fake Syphon one which is flipped, each with a marker at the top of its picture: both upright in the assembled movie's first picture). Update `testOSCQueryDescribesEveryParameter` for the new addresses.
- [ ] **Step 2–4:** fail, implement, pass; whole suite. **Step 5:** commit "One directory for Syphon and NDI; a place knows its kind".

### Task 6: The window, and the app's bundle

**Files:** Modify `App/SimpleRecorderApp.swift`, `App/RecorderModel.swift`, `App/Views/{SourcesSidebar,StatusBar}.swift`, `Resources/Info.plist`, `Scripts/bundle.sh`, `Tests/SimpleRecorderTests/{Fakes,RecorderModelTests,ViewRenderingTests}.swift`.

- **App**: the controller's directory is `CompositeDirectory([SyphonDirectory(), NDIDirectory(library: .shared)])`; `controller.ndiAvailable = NDILibrary.shared.isAvailable`. One line in the log at launch: the library's version and path, or why NDI is off.
- **Model**: `Source.kind` and `Place.kind` (`"syphon"`, `"ndi"`), `ndiAvailable`.
- **Sidebar**: a row's second line is its application for Syphon, `NDI` for NDI (already its detail); an NDI row also carries a small `NDI` tag at its right, so that the two kinds are told apart at a glance. Nothing else changes: ticking, order, dimming.
- **Status bar**: after the ports, `NDI on` or `NDI off` (dim; `NDI off` has a tool tip with the library's `reason`).
- **Info.plist**: `_ndi._tcp` added to `NSBonjourServices`; the Local Network sentence also says NDI sources are found on the network.
- **bundle.sh**: if `/Library/NDI SDK for Apple/lib/macOS/libndi.dylib` exists (or `NDI_LIBRARY=<path>`), copy it to `Contents/Frameworks/libndi.dylib` and sign it with the app's identity, before the app; otherwise print "NDI's library was not found: the app is built without it" and go on. `codesign --verify --deep --strict` still passes either way.

- [ ] **Step 1:** model tests: `testASourcesKindFollowsItsDirectory` (the fakes list two NDI sources: `available` and, once ticked, `places` say `ndi`); `testNDIAvailabilityFollowsTheController`.
- [ ] **Step 2:** rendered views (`build/views/`): `8-ndi-sources` (two Syphon and two NDI sources available, one of each ticked, "NDI on"); `9-ndi-off` — **read the pictures**: the tag, the status bar, nothing displaced.
- [ ] **Step 3–4:** implement until green and the pictures are right; `Scripts/bundle.sh`; `codesign --verify`; `ls "build/Simple Recorder.app/Contents/Frameworks"` shows `libndi.dylib`; launched on test ports, `curl localhost:19231/status/ndi?VALUE` answers 1. **Step 5:** `NDI_LIBRARY=/nonexistent Scripts/bundle.sh` builds an app without the library and says so; that app, launched with `SIMPLE_NDI_LIBRARY=/nonexistent`, answers 0. Rebuild with the library afterwards. **Step 6:** commit "NDI sources in the window; the library in the app".

### Task 7: MCP, a test sender, documentation

**Files:** Create `Tools/ndi-send.m`; modify `Tools/build.sh`, `MCP/main.swift`, `README.md`, `DECISIONS.md`, `CLAUDE.md`.

- [ ] **Step 1:** `Tools/ndi-send.m` → `build/tools/ndi-send <name> [width height fps] [--bgrx]`: an NDI sender of Simple Server's test pattern (pulsing background, sweeping bar, orange marker at the top left), loaded through `dlopen` as the app does; ends on SIGTERM. `Tools/build.sh` builds it (and says so if the headers' path changed).
- [ ] **Step 2:** MCP: `recorder_status` gives `ndi` (true/false), `sources[].kind`, and `sourcesAvailable` as a list of `{title, kind}` — **a change of shape**: say so in the tool's description and in `DECISIONS.md`; `recorder_configure`'s `sources` still takes titles. The server's instructions say Syphon and NDI.
- [ ] **Step 3:** README (NDI sources, what is needed — the NDI runtime or SDK, or the library bundled by `bundle.sh` —, the three new addresses, the trademark line, "sound comes in part 4"), `DECISIONS.md` (D56…: the library loaded at run time and where it is searched; BGRA asked of the SDK rather than converted here; arrival time, not NDI's timestamps; the ring of six; the kind told by `/status/ndi/sources`; Syphon before NDI for a same title; what "alive" means for NDI; what the SDK's documentation says of BGRA's alpha — premultiplied or not — and what the movies therefore hold), `CLAUDE.md` (part 3 done; part 4 remains; the rules this part cost).
- [ ] **Step 4:** `swift test`, `Tools/build.sh`, `Scripts/bundle.sh`. **Step 5:** commit "MCP, a test sender and documentation for NDI".

### Task 8: End to end, review

- [ ] **Step 1:** Adrien's preferences exported. The signed bundle on test ports, Simple Servers A and B, `ndi-send N1` (1280 × 720, 30) and `ndi-send N2` (960 × 540, 60, `--bgrx`): the four are listed, with their kinds, over OSCQuery and MCP; the Local Network permission of the signed app is what lets the NDI ones be found — if they are not, say so to Adrien rather than work around it.
- [ ] **Step 2:** `/output both`, `/layout grid`, 5 s at 30 fps → five movies; **read a frame of each back and look at it**: every pattern upright, its marker at its own top left, NDI and Syphon side by side; the NDI movies at their senders' sizes.
- [ ] **Step 3:** `prores4444`, assembled: the BGRX source opaque, the gaps transparent.
- [ ] **Step 4:** kill `ndi-send N1` during an assembled take and relaunch it → its place black then alive, the movie whole; note how long each takes. `kill -TERM` the app during a take with NDI sources → every movie finished, the app gone within a few seconds (no thread left waiting).
- [ ] **Step 5:** eight sources, four of them NDI at 1080p60, `both`, HEVC, 20 s: drops and CPU noted (NDI is decoded on the CPU).
- [ ] **Step 6:** the app launched with `SIMPLE_NDI_LIBRARY=/nonexistent`: "NDI off", Syphon sources recorded as before.
- [ ] **Step 7:** MCP over stdio: status (kinds), configure with an NDI title, start, stop.
- [ ] **Step 8:** Adrien's preferences re-imported, keys added by the run removed, test processes killed by PID.
- [ ] **Step 9:** whole-branch review by a fresh reviewer, with this plan's Review Focus; one fix pass, each fix with a test which failed first; the smoke take redone on the rebuilt bundle; commit; push `ndi`.
