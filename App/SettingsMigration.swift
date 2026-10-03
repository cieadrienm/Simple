/*
 SettingsMigration.swift
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

/// Simple Recorder was Simple Client: the recorder's settings made there are taken over, once.
enum SettingsMigration {
    static let oldDomain = "net.am-cb.simple-client"
    private static let keys = ["RecorderCodec", "RecorderWidth", "RecorderHeight", "RecorderFPS", "RecorderBitrate", "RecorderFolder", "RecorderName"]
    private static let marker = "SettingsMigratedFromSimpleClient"

    /// Copies the recorder's settings which `domain` does not have yet from `oldDomain`. Does nothing the second time.
    ///
    /// The domains are read as they were saved, not through `object(forKey:)`: that also answers the defaults the
    /// recorder registers, which are not settings anyone made.
    static func migrate(from oldDomain: String, to defaults: UserDefaults, domain: String) {
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        let old = defaults.persistentDomain(forName: oldDomain) ?? [:]
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        for key in keys {
            if let value = old[key], existing[key] == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
