/*
 StatusBar.swift
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

/// The state: how the recorder can be reached, and what a recording will write, and where.
struct StatusBar: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 16) {
            if model.oscPort > 0 {
                Text("OSC :\(String(model.oscPort))")
                Text("OSCQuery :\(String(model.oscQueryPort))")
            } else {
                Text("OSC is not available")
            }
            Spacer()
            if !model.failure.isEmpty && !model.isRecording {
                Text(model.failure).foregroundStyle(Theme.record).lineLimit(1)
            }
            Text(summary)
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.textFaint)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.panel)
    }

    private var summary: String {
        var parts: [String] = []
        if let free = model.freeSpace {
            parts.append("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
        }
        parts.append(model.movieCount == 1 ? "1 movie" : "\(model.movieCount) movies")
        return parts.joined(separator: " \u{00B7} ")
    }
}
