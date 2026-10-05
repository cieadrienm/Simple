import XCTest
import SwiftUI
import RecorderKit
@testable import SimpleRecorder

/// The window cannot be looked at from here: it is drawn off screen, in the states which matter, to pictures in
/// build/views which a person (or the agent which wrote the views) reads.
@MainActor
final class ViewRenderingTests: XCTestCase {
    private var recorder: TestRecorder!
    private var model: RecorderModel!
    private static let size = NSSize(width: 1100, height: 680)

    override func setUp() async throws {
        recorder = try TestRecorder()
        model = RecorderModel(controller: recorder.controller, errorDisplayTime: 30)
    }

    override func tearDown() async throws {
        recorder.cleanUp()
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func deliver(_ seconds: Double) {
        let textures = Dictionary(uniqueKeysWithValues: TestRecorder.titles.enumerated().map { ($1, recorder.texture(640, 360, grey: UInt8(60 + $0 * 40))) })
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for (title, texture) in textures { recorder.directory.source(title)?.deliver(texture) }
            spin(0.02)
        }
    }

    /// Draws the window's content to a bitmap, and to build/views/<name>.png.
    private func render(_ name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: ContentView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.3)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/views")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(name).png"))
        return bitmap
    }

    /// How many different colours a bitmap has in a sample of its pixels: a blank picture has one.
    private func colours(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                if let colour = bitmap.colorAt(x: x, y: y) {
                    seen.insert("\(Int(colour.redComponent * 255))-\(Int(colour.greenComponent * 255))-\(Int(colour.blueComponent * 255))")
                }
            }
        }
        return seen.count
    }

    func testTheWindowWithNothingTicked() throws {
        XCTAssertGreaterThan(colours(try render("1-nothing-ticked")), 8)
    }

    func testTheWindowWithThreeSourcesTicked() throws {
        for title in ["main view - eMotion", "depthMap - eMotion", "A - Simple Server"] { model.tick(title) }
        deliver(0.8)
        XCTAssertGreaterThan(colours(try render("2-three-ticked")), 8)
    }

    func testTheWindowWhileRecording() throws {
        XCTAssertTrue(recorder.controller.startNetwork(withOSCPort: 19630, queryPort: 19631, name: "Render Test"))
        for title in ["main view - eMotion", "A - Simple Server"] { model.tick(title) }
        model.setName("Répétition")
        model.setCodec("hevc")
        model.setFPS(50)
        deliver(0.5)
        let idle = try render("3a-before-recording")
        model.toggleRecording()
        deliver(1.2)
        let recording = try render("3b-recording")
        XCTAssertNotEqual(idle.tiffRepresentation, recording.tiffRepresentation, "recording must show")
        model.toggleRecording()
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
    }

    func testTheWindowAfterAFailureAndWithAnError() throws {
        model.tick("A - Simple Server")
        model.toggleRecording()
        model.toggleRecording()
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
        XCTAssertGreaterThan(colours(try render("4a-failure")), 8)
        recorder.controller.handle(OSCMessage(address: "/record <0>", arguments: []))
        XCTAssertGreaterThan(colours(try render("4b-error")), 8)
    }

    // MARK: The assembled picture

    private let three = ["main view - eMotion", "depthMap - eMotion", "A - Simple Server"]

    func testTheWindowInEachLayout() throws {
        for title in three { model.tick(title) }
        deliver(0.6)
        var pictures: [Data?] = []
        for layout in ["row", "column", "grid", "focus"] {
            model.setLayout(layout)
            deliver(0.4)
            pictures.append(try render("5-layout-\(layout)").tiffRepresentation)
        }
        XCTAssertEqual(Set(pictures).count, 4, "each layout must show")
    }

    func testTheWindowWhileRecordingBoth() throws {
        for title in three { model.tick(title) }
        model.setOutput("both")
        model.setLayout("focus")
        model.setGap(8)
        model.setSize(width: 1920, height: 1080)
        model.setName("Répétition")
        deliver(0.5)
        model.toggleRecording()
        deliver(1.2)
        XCTAssertGreaterThan(colours(try render("6-recording-both")), 8)
        model.toggleRecording()
        let deadline = Date().addingTimeInterval(10)
        while model.isRecording && Date() < deadline { spin(0.02) }
    }

    func testTheWindowWithASourceAway() throws {
        for title in three { model.tick(title) }
        model.setOutput("assembled")
        deliver(0.5)
        // depthMap's application quits; the two others go on
        recorder.directory.setTitles(TestRecorder.titles.filter { $0 != "depthMap - eMotion" })
        deliver(1.5)
        XCTAssertEqual(model.places.map(\.isOnline), [true, false, true])
        XCTAssertGreaterThan(colours(try render("7-one-away")), 8)
    }

    // MARK: NDI

    private func useNDISources(available: Bool) throws {
        recorder.cleanUp()
        recorder = try TestRecorder(ndi: ["STUDIO (Camera 1)", "STUDIO (Camera 2)"])
        recorder.controller.ndiAvailable = available
        model = RecorderModel(controller: recorder.controller, errorDisplayTime: 30,
                              ndiOffReason: available ? "" : "libndi.dylib was not found")
    }

    func testTheWindowWithNDISources() throws {
        try useNDISources(available: true)
        model.tick("A - Simple Server")
        model.tick("STUDIO (Camera 1)")
        spin(0.3)
        XCTAssertEqual(model.places.map(\.kind), ["syphon", "ndi"])
        XCTAssertGreaterThan(colours(try render("8-ndi-sources")), 8)
    }

    func testTheWindowWithSound() throws {
        try useNDISources(available: true)
        model.tick("STUDIO (Camera 1)")
        model.tick("STUDIO (Camera 2)")
        model.setOutput("both")
        model.setSound("STUDIO (Camera 2)")
        try XCTUnwrap(recorder.directory.source("STUDIO (Camera 2)")).deliverSound(SourceSound.silence(ofFrameCount: 960, sampleRate: 48000))
        spin(0.3)
        XCTAssertEqual(model.places.map(\.hasSound), [false, true])
        XCTAssertGreaterThan(colours(try render("10-sound")), 8)
    }

    func testTheWindowWithTheSoundOfASourceWhichIsNotSelected() throws {
        try useNDISources(available: true)
        model.tick("STUDIO (Camera 1)")
        model.tick("STUDIO (Camera 2)")
        model.setOutput("both")
        model.setSound("STUDIO (Camera 2)")
        model.untick(place: 2)
        spin(0.3)
        XCTAssertEqual(model.sound, "STUDIO (Camera 2)")
        XCTAssertEqual(model.places.map(\.title), ["STUDIO (Camera 1)"])
        XCTAssertGreaterThan(colours(try render("11-sound-not-selected")), 8)
    }

    func testTheWindowWithoutNDI() throws {
        try useNDISources(available: false)
        model.tick("A - Simple Server")
        send("/fps", NSNumber(value: 30))
        XCTAssertFalse(model.ndiAvailable)
        XCTAssertGreaterThan(colours(try render("9-ndi-off")), 8)
    }

    private func send(_ address: String, _ arguments: Any...) {
        recorder.controller.handle(OSCMessage(address: address, arguments: arguments))
    }

    func testTheMonitorIsDrawnAtTheDisplaysRate() {
        // What is shown must be as smooth as its source: sixty pictures a second at least, more on a faster display
        let view = FrameView(device: recorder.device) { (nil, false) }
        XCTAssertGreaterThanOrEqual(view.preferredFramesPerSecond, 60)
        XCTAssertGreaterThanOrEqual(view.preferredFramesPerSecond, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
        XCTAssertFalse(view.isPaused)
    }
}
