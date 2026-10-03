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
    }

    /// A source which can be chosen
    struct Source: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var detail: String
    }

    let controller: RecorderController

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
    @Published private(set) var oscPort = 0
    @Published private(set) var oscQueryPort = 0
    /// Bytes free on the disk of the folder, nil if it cannot be told
    @Published private(set) var freeSpace: Int64?

    var isRecording: Bool { state != "idle" }
    /// The movies a recording writes: one for each source
    var movieCount: Int { places.count }
    static let codecs: [(name: String, title: String)] = [("h264", "H.264"), ("hevc", "HEVC"), ("prores422", "ProRes 422"), ("prores4444", "ProRes 4444")]
    /// Whether the codec has a bitrate to choose
    var codecHasBitrate: Bool { codec == "h264" || codec == "hevc" }

    private let errorDisplayTime: TimeInterval
    private var lastErrorCount: UInt = 0
    private var observer: NSObjectProtocol?
    private var lastSpaceCheck = Date.distantPast

    init(controller: RecorderController, errorDisplayTime: TimeInterval = 6) {
        self.controller = controller
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
        set(\.oscPort, controller.oscPort)
        set(\.oscQueryPort, controller.oscQueryPort)
        set(\.failure, controller.recordingError)

        let chosen = controller.places.map {
            Place(title: $0.title, isOnline: $0.isOnline, width: $0.width, height: $0.height, fps: ($0.fps * 10).rounded() / 10,
                  file: $0.file, frames: Int($0.frames), dropped: Int($0.dropped))
        }
        set(\.places, chosen)
        let titles = Set(chosen.map(\.title))
        set(\.available, controller.availableSources.filter { !titles.contains($0.title) }.map { Source(title: $0.title, detail: $0.detail) })

        showError(controller.error)
        checkSpace()
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
}
