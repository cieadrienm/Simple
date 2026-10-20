/*
 SimpleRecorderApp.swift
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

import SwiftUI
import Metal
import RecorderKit

@main
struct SimpleRecorderApp: App {
    /// The name of the app: in the window, in OSCQuery, in the names of movies
    static let name = "Simple Recorder"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(Self.name, id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Self.name)") {
                    AboutWindowController.shared.show(model: delegate.model) {
                        HelpWindowController.shared.show(version: delegate.model.version)
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                RecordCommand(model: delegate.model)
            }
            CommandGroup(replacing: .help) {
                Button("\(Self.name) Help") {
                    HelpWindowController.shared.show(version: delegate.model.version)
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Recording & Layouts") {
                    HelpWindowController.shared.show(section: "dispositions", version: delegate.model.version)
                }
                Button("Sound (NDI & Computer)") {
                    HelpWindowController.shared.show(section: "son", version: delegate.model.version)
                }
                Button("OSC & OSCQuery") {
                    HelpWindowController.shared.show(section: "osc", version: delegate.model.version)
                }
                Button("Troubleshooting") {
                    HelpWindowController.shared.show(section: "depannage", version: delegate.model.version)
                }
            }
        }
    }
}

/// File ▸ Start Recording, which says Stop Recording while a recording is in progress.
struct RecordCommand: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
            .keyboardShortcut("r")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The ports we listen on unless the environment says otherwise, which lets a second copy run beside the first
    private static let defaultOSCPort = 9230
    private static let defaultOSCQueryPort = 9231

    let model: RecorderModel
    private var terminationSource: DispatchSourceSignal?

    override init() {
        // Without Metal there is nothing to show nor to record
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Simple Recorder needs Metal") }
        // Simple Recorder was Simple Client: its settings are taken over, once
        SettingsMigration.migrate(from: SettingsMigration.oldDomain, to: .standard, domain: Bundle.main.bundleIdentifier ?? "net.am-cb.simple-recorder")
        // NDI works only if its library was found: a missing library is a state, not an error
        let ndi = NDILibrary.shared()
        let directory = CompositeDirectory(directories: [SyphonDirectory(), NDIDirectory(library: ndi)])
        let controller = RecorderController(device: device, directory: directory, defaults: .standard)
        controller.ndiAvailable = ndi.isAvailable
        if ndi.isAvailable {
            NSLog("NDI is on: %@ (%@)", ndi.version, ndi.path ?? "")
        } else {
            NSLog("NDI is off: %@", ndi.reason)
        }
        model = RecorderModel(controller: controller, ndiOffReason: ndi.reason)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        let oscPort = environment["SIMPLE_OSC_PORT"].flatMap(Int.init) ?? Self.defaultOSCPort
        let queryPort = environment["SIMPLE_OSCQUERY_PORT"].flatMap(Int.init) ?? Self.defaultOSCQueryPort
        model.controller.startNetwork(withOSCPort: oscPort, queryPort: queryPort, name: SimpleRecorderApp.name)

        // When we are asked to terminate by a signal (kill, or a script which stops a show) quit as we do from the
        // menu, so that the movies being recorded are finished
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Not from this block: terminating waits for the movies to be finished, which is reported on the main
            // queue, and the main queue does nothing else until this block returns
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0, inModes: [.common])
        }
        source.resume()
        terminationSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.controller.isRecording else { return .terminateNow }
        // Finish the movies before we go
        model.controller.stop {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
