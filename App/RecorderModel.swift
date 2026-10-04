/*
 RecorderModel.swift
 Simple

 Copyright 2026 Adrien Mondot.
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation
import Combine
import RecorderKit

/// What the window shows of the recorder, and what it can ask of it.
///
/// The recorder itself is `RecorderController`: this follows it (it says when something changed), so that
/// whatever changes the recorder — the window, an OSC message, the MCP tool — the window shows it.
@MainActor
final class RecorderModel: ObservableObject {
    /// One of the sources chosen for recording
    struct Place: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var isOnline: Bool
        var width: Int
        var height: Int
        var fps: Double
        var file: String
        var frames: Int
        var dropped: Int
        /// "syphon" or "ndi"; empty while the place has never been connected
        var kind: String
    }

    /// A source which can be chosen
    struct Source: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var detail: String
        /// "syphon" or "ndi"
        var kind: String
    }

    let controller: RecorderController
    /// Why NDI is off, for the status bar's tool tip (the library knows; the views do not touch it)
    let ndiOffReason: String

    @Published private(set) var state = "idle"
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var frames = 0
    @Published private(set) var dropped = 0
    @Published private(set) var places: [Place] = []
    /// The sources which are not chosen
    @Published private(set) var available: [Source] = []
    /// The recorder's last error, for a few seconds after it happened
    @Published private(set) var notice = ""
    /// Why the last recording ended, if it was not as asked: stays until the next one
    @Published private(set) var failure = ""
    @Published private(set) var codec = ""
    @Published private(set) var fps: Double = 0
    @Published private(set) var bitrate: Double = 0
    @Published private(set) var folder = ""
    @Published private(set) var name = ""
    /// What a recording writes: "separate", "assembled" or "both"
    @Published private(set) var output = "separate"
    /// How the sources are assembled: "row", "column", "grid" or "focus"
    @Published private(set) var layout = "row"
    @Published private(set) var gap = 0
    /// The size the assembled picture is fitted into, 0 for the size the sources need
    @Published private(set) var width = 0
    @Published private(set) var height = 0
    /// The size of the assembled picture, zero if there is no source
    @Published private(set) var pictureSize = CGSize.zero
    /// Where each source is in the assembled picture: from 0 to 1, from its top left
    @Published private(set) var titleRects: [CGRect] = []
    @Published private(set) var assembledFrames = 0
    @Published private(set) var assembledDropped = 0
    /// Whether NDI's library is loaded: without it NDI sources are not listed
    @Published private(set) var ndiAvailable = false
    @Published private(set) var oscPort = 0
    @Published private(set) var oscQueryPort = 0
    /// Bytes free on the disk of the folder, nil if it cannot be told
    @Published private(set) var freeSpace: Int64?

    var isRecording: Bool { state != "idle" }
    /// The movies a recording writes: one for each source, one for them all, or both
    var movieCount: Int {
        guard !places.isEmpty else { return 0 }
        switch output {
        case "assembled": return 1
        case "both": return places.count + 1
        default: return places.count
        }
    }
    static let outputs: [(name: String, title: String)] = [("separate", "Separate"), ("assembled", "Assembled"), ("both", "Both")]
    static let layouts: [(name: String, title: String, symbol: String)] = [
        ("row", "Side by side", "rectangle.split.3x1"), ("column", "Stacked", "rectangle.split.1x2"),
        ("grid", "Mosaic", "rectangle.split.2x2"), ("focus", "One large", "rectangle.trailingthird.inset.filled")]
    /// The largest picture which can be composed and written, on a side
    static let largestSide: CGFloat = 16384
    /// Whether a recording would be refused for the size of its assembled picture. Separate movies do not care.
    var pictureIsTooLarge: Bool {
        output != "separate" && (pictureSize.width > Self.largestSide || pictureSize.height > Self.largestSide)
    }
    static let codecs: [(name: String, title: String)] = [("h264", "H.264"), ("hevc", "HEVC"), ("prores422", "ProRes 422"), ("prores4444", "ProRes 4444")]
    /// Whether the codec has a bitrate to choose
    var codecHasBitrate: Bool { codec == "h264" || codec == "hevc" }

    private let errorDisplayTime: TimeInterval
    private var lastErrorCount: UInt = 0
    private var observer: NSObjectProtocol?
    private var lastSpaceCheck = Date.distantPast

    init(controller: RecorderController, errorDisplayTime: TimeInterval = 6, ndiOffReason: String = "") {
        self.controller = controller
        self.ndiOffReason = ndiOffReason
        self.errorDisplayTime = errorDisplayTime
        lastErrorCount = controller.errorCount
        observer = NotificationCenter.default.addObserver(forName: .RecorderControllerDidChange, object: controller, queue: nil) { [weak self] _ in
            // The controller is used on the main thread, and says so there
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Published values are only set when they change: the controller speaks four times a second.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<RecorderModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func sync() {
        set(\.state, controller.state)
        // To the tenth of a second: finer would redraw the window for nothing
        set(\.elapsed, (controller.elapsed * 10).rounded(.down) / 10)
        set(\.frames, Int(controller.frames))
        set(\.dropped, Int(controller.dropped))
        set(\.codec, controller.codec)
        set(\.fps, controller.fps)
        set(\.bitrate, controller.bitrate)
        set(\.folder, controller.folder)
        set(\.name, controller.name)
        set(\.output, controller.output)
        set(\.layout, controller.layout)
        set(\.gap, controller.gap)
        set(\.width, controller.width)
        set(\.height, controller.height)
        set(\.assembledFrames, Int(controller.assembledFrames))
        set(\.assembledDropped, Int(controller.assembledDropped))
        set(\.ndiAvailable, controller.ndiAvailable)
        set(\.oscPort, controller.oscPort)
        set(\.oscQueryPort, controller.oscQueryPort)
        set(\.failure, controller.recordingError)

        let chosen = controller.places.map {
            Place(title: $0.title, isOnline: $0.isOnline, width: $0.width, height: $0.height, fps: ($0.fps * 10).rounded() / 10,
                  file: $0.file, frames: Int($0.frames), dropped: Int($0.dropped), kind: $0.kindName)
        }
        set(\.places, chosen)
        let picture = controller.assembledLayout
        let size = chosen.isEmpty ? CGSize.zero : picture.size
        set(\.pictureSize, size)
        set(\.titleRects, chosen.isEmpty ? [] : picture.frames.map {
            let rect = $0.rectValue
            return CGRect(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height)
        })
        let titles = Set(chosen.map(\.title))
        set(\.available, controller.availableSources.filter { !titles.contains($0.title) }.map { Source(title: $0.title, detail: $0.detail, kind: Self.kindName($0.kind)) })

        showError(controller.error)
        checkSpace()
    }

    private static func kindName(_ kind: FrameSourceKind) -> String {
        kind == .NDI ? "ndi" : "syphon"
    }

    /// A new error is shown for a while; why a recording ended is `failure`, which stays.
    private func showError(_ error: String) {
        let count = controller.errorCount
        if error.isEmpty {
            // A recording has started: what was wrong before no longer is
            if !notice.isEmpty { notice = "" }
            return
        }
        guard count != lastErrorCount else { return }
        lastErrorCount = count
        notice = error
        DispatchQueue.main.asyncAfter(deadline: .now() + errorDisplayTime) { [weak self] in
            // Unless another error has taken its place
            guard let self, self.lastErrorCount == count else { return }
            self.notice = ""
        }
    }

    private func checkSpace() {
        guard Date().timeIntervalSince(lastSpaceCheck) > 2 else { return }
        lastSpaceCheck = Date()
        let values = try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        set(\.freeSpace, values?.volumeAvailableCapacityForImportantUsage)
    }

    // MARK: What the window asks

    func toggleRecording() { controller.toggle() }

    func tick(_ title: String) { controller.addSource(matching: title) }

    /// place: from 1
    func untick(place: Int) { controller.removeSource(atPlace: UInt(place)) }

    func move(from: Int, to: Int) { controller.moveSource(fromPlace: UInt(from), toPlace: UInt(to)) }

    func setCodec(_ codec: String) { controller.codec = codec }
    func setFPS(_ fps: Double) { controller.fps = fps }
    func setBitrate(_ bitrate: Double) { controller.bitrate = bitrate }
    func setFolder(_ folder: String) { controller.folder = folder }
    func setName(_ name: String) { controller.name = name }
    func setOutput(_ output: String) { controller.output = output }
    func setLayout(_ layout: String) { controller.layout = layout }
    func setGap(_ gap: Int) { controller.gap = gap }
    /// 0 and 0 for the size the sources need
    func setSize(width: Int, height: Int) {
        controller.width = width
        controller.height = height
    }
}
