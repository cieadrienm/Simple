/*
 SourcesSidebar.swift
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

/// The sources: those chosen, in the order which is theirs in a recording, then those which can be.
struct SourcesSidebar: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        List {
            Section {
                ForEach(Array(model.places.enumerated()), id: \.element.id) { index, place in
                    SourceRow(title: place.title, detail: detail(place), isNDI: place.kind == "ndi", hasSound: place.hasSound, isChosen: true, isDimmed: !place.isOnline) {
                        model.untick(place: index + 1)
                    }
                }
                .onMove { offsets, destination in
                    guard let from = offsets.first else { return }
                    // The place it ends up in, counted once it has left its own
                    model.move(from: from + 1, to: (destination > from ? destination - 1 : destination) + 1)
                }
                if model.places.isEmpty {
                    Text("None yet").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
            } header: {
                Theme.sectionTitle("Sources")
            }
            if !model.available.isEmpty {
                Section {
                    ForEach(model.available) { source in
                        SourceRow(title: source.title, detail: source.detail, isNDI: source.kind == "ndi", hasSound: false, isChosen: false, isDimmed: false) {
                            model.tick(source.title)
                        }
                    }
                } header: {
                    Theme.sectionTitle("Available")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        // The sources of a recording cannot change while it is made
        .disabled(model.isRecording)
    }

    private func detail(_ place: RecorderModel.Place) -> String {
        guard place.isOnline else { return place.width > 0 ? "Away" : "Waiting for it" }
        return "\(place.width) \u{00D7} \(place.height) \u{00B7} \(Int(place.fps.rounded())) fps"
    }
}

struct SourceRow: View {
    let title: String
    let detail: String
    let isNDI: Bool
    /// Its source is delivering sound, which its movie records
    let hasSound: Bool
    let isChosen: Bool
    let isDimmed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { isChosen }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(isChosen ? "Stop recording \(title)" : "Record \(title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12)).foregroundStyle(isDimmed ? Theme.textDim : Theme.text).lineLimit(1)
                Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            if isNDI {
                Spacer(minLength: 4)
                if hasSound {
                    Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        .help("This source has sound")
                        .accessibilityLabel("Has sound")
                }
                // Tells NDI sources from Syphon's at a glance
                Text("NDI").font(Theme.mono(9, .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
                    .accessibilityLabel("NDI source")
            }
        }
        .padding(.vertical, 2)
    }
}
