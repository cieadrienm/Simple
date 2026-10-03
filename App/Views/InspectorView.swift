/*
 InspectorView.swift
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
import AppKit

/// The settings: of the movies, and of where they go.
struct InspectorView: View {
    @ObservedObject var model: RecorderModel
    private static let rates: [Double] = [0, 24, 25, 30, 50, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionTitle("Movie")
            row("Codec") {
                Picker("", selection: Binding(get: { model.codec }, set: { model.setCodec($0) })) {
                    ForEach(RecorderModel.codecs, id: \.name) { Text($0.title).tag($0.name) }
                }
                .labelsHidden()
            }
            row("Frame rate") {
                Picker("", selection: Binding(get: { model.fps }, set: { model.setFPS($0) })) {
                    ForEach(rates, id: \.self) { rate in
                        Text(rate == 0 ? "Same as source" : String(format: "%g", rate)).tag(rate)
                    }
                }
                .labelsHidden()
            }
            row("Bitrate") {
                HStack(spacing: 6) {
                    TextField("Automatic", value: Binding(get: { model.bitrate == 0 ? nil : model.bitrate }, set: { model.setBitrate($0 ?? 0) }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.codecHasBitrate)
                    Text("Mbit/s").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }

            Theme.sectionTitle("Files").padding(.top, 10)
            row("Folder") {
                Button(action: chooseFolder) {
                    Label(URL(fileURLWithPath: model.folder).lastPathComponent, systemImage: "folder")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(model.folder)
            }
            row("Name") {
                TextField("Date and time", text: Binding(get: { model.name }, set: { model.setName($0) }))
                    .textFieldStyle(.roundedBorder)
            }
            Text(model.movieCount > 1 ? "Each movie adds its source\u{2019}s title to the name." : "A movie is never overwritten: a number is added.")
                .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .controlSize(.small)
        .padding(14)
        .background(Theme.panel)
    }

    /// The rates offered, with the one in use if it is another
    private var rates: [Double] {
        Self.rates.contains(model.fps) ? Self.rates : Self.rates + [model.fps]
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textDim).frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: model.folder)
        if panel.runModal() == .OK, let url = panel.url {
            model.setFolder(url.path)
        }
    }
}
