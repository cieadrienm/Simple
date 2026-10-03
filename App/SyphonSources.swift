/*
 SyphonSources.swift
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
import Metal
import RecorderKit
import Syphon

/// A Syphon server which is connected to: it delivers the server's frames until it is stopped.
final class SyphonSource: NSObject, FrameSource {
    let title: String
    /// Syphon frames have their first row at the bottom of the picture
    let flipped = true

    private var client: SyphonMetalClient?
    private let lock = NSLock()
    private var handler: ((MTLTexture) -> Void)?

    /// Set on the main thread, called on Syphon's.
    var frameHandler: ((MTLTexture) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    init(title: String, serverDescription: [String: Any], device: MTLDevice) {
        self.title = title
        super.init()
        client = SyphonMetalClient(serverDescription: serverDescription, device: device, options: nil) { [weak self] client in
            guard let self, let handler = self.frameHandler, let frame = client.newFrameImage() else { return }
            handler(frame)
        }
    }

    func stop() {
        client?.stop()
        client = nil
    }

    deinit {
        client?.stop()
    }
}

/// The Syphon servers which are running.
final class SyphonDirectory: NSObject, SourceDirectory {
    var changeHandler: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        // The directory tells of servers which arrive, change (their name, for instance) and leave
        let names: [NSNotification.Name] = [.SyphonServerAnnounce, .SyphonServerUpdate, .SyphonServerRetire]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.changeHandler?()
            }
        }
        // Looking at the directory is what makes it start listening
        _ = SyphonServerDirectory.shared().servers
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The title a server is shown with: "name - application", or whichever of the two it has.
    static func title(for description: [String: Any]) -> String {
        let name = description[SyphonServerDescriptionNameKey] as? String ?? ""
        let application = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
        if !application.isEmpty {
            // A server may have no name (usually when it is the only server of its application)
            return name.isEmpty ? application : "\(name) - \(application)"
        }
        return name.isEmpty ? "Untitled Server" : name
    }

    private var servers: [[String: Any]] {
        SyphonServerDirectory.shared().servers
    }

    func availableSources() -> [SourceDescription] {
        servers.map { description in
            let application = description[SyphonServerDescriptionAppNameKey] as? String ?? ""
            return SourceDescription(title: Self.title(for: description), detail: application.isEmpty ? "Syphon" : application, kind: .syphon)
        }
    }

    func connectToSource(withTitle title: String, device: MTLDevice) -> FrameSource? {
        // Of servers with the same title, the first
        guard let description = servers.first(where: { Self.title(for: $0) == title }) else { return nil }
        return SyphonSource(title: title, serverDescription: description, device: device)
    }
}
