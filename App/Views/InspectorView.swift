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

/// The settings: of the movies, of the assembled picture, and of where they go.
struct InspectorView: View {
    @ObservedObject var model: RecorderModel
    private static let rates: [Double] = [0, 24, 25, 30, 50, 60]
    private static let sizes: [(width: Int, height: Int)] = [(1920, 1080), (3840, 2160)]
    /// "Custom" was chosen: the fields stay even when what they hold is one of the sizes offered
    @State private var customSize = false

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

            Theme.sectionTitle("Assembled").padding(.top, 10)
            // The picture of a take does not change: these are for the next one
            Group {
                row("Size") {
                    Picker("", selection: Binding(get: { sizeChoice }, set: { chooseSize($0) })) {
                        Text("Automatic").tag("auto")
                        ForEach(Self.sizes, id: \.width) { Text(verbatim: "\($0.width) \u{00D7} \($0.height)").tag("\($0.width)x\($0.height)") }
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden()
                }
                if sizeChoice == "custom" {
                    row("") {
                        HStack(spacing: 4) {
                            TextField("Width", value: Binding(get: { model.width }, set: { model.setSize(width: $0, height: model.height) }), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                            Text("\u{00D7}").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            TextField("Height", value: Binding(get: { model.height }, set: { model.setSize(width: model.width, height: $0) }), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                row("Gap") {
                    HStack(spacing: 6) {
                        TextField("0", value: Binding(get: { model.gap }, set: { model.setGap($0) }), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                        Text("pixels").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                }
                row("Sound") {
                    Picker("", selection: Binding(get: { model.sound }, set: { model.setSound($0) })) {
                        Text("None").tag("")
                        ForEach(soundTitles, id: \.self) { Text($0).tag($0) }
                        if !model.sound.isEmpty && !soundTitles.contains(model.sound) {
                            Text("\(model.sound) (not selected)").tag(model.sound)
                        }
                    }
                    .labelsHidden()
                    .help("The source whose sound the assembled movie takes")
                }
                // Only the assembled movie takes it: the setting stays in sight
                .opacity(model.output == "separate" ? 0.5 : 1)
                if !model.sound.isEmpty && !soundTitles.contains(model.sound) {
                    // The picker's text is cut at this width: the hint says what its entry says
                    Text("\(model.sound) is not selected: the assembled movie has no sound.")
                        .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(model.output == "separate" ? 0.5 : 1)
                }
            }
            .disabled(model.isRecording)

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
            Text(namingHint)
                .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .controlSize(.small)
        .padding(14)
        .background(Theme.panel)
    }

    private var namingHint: String {
        switch model.output {
        case "both": return "The assembled movie has the name; each source\u{2019}s adds its title."
        case "assembled": return "A movie is never overwritten: a number is added."
        default: return model.movieCount > 1 ? "Each movie adds its source\u{2019}s title to the name." : "A movie is never overwritten: a number is added."
        }
    }

    /// "auto", one of the sizes offered as "1920x1080", or "custom"
    private var sizeChoice: String {
        if customSize { return "custom" }
        if model.width == 0 || model.height == 0 { return "auto" }
        return Self.sizes.contains { $0.width == model.width && $0.height == model.height } ? "\(model.width)x\(model.height)" : "custom"
    }

    private func chooseSize(_ choice: String) {
        customSize = choice == "custom"
        if choice == "auto" {
            model.setSize(width: 0, height: 0)
        } else if let size = Self.sizes.first(where: { "\($0.width)x\($0.height)" == choice }) {
            model.setSize(width: size.width, height: size.height)
        } else if model.width == 0 || model.height == 0 {
            // The fields start from the picture as it is
            let picture = model.pictureSize
            model.setSize(width: picture.width > 0 ? min(Int(picture.width), Int(RecorderModel.largestSide)) : 1920,
                          height: picture.height > 0 ? min(Int(picture.height), Int(RecorderModel.largestSide)) : 1080)
        }
    }

    /// The NDI sources which are chosen: sound may come from any of them
    private var soundTitles: [String] {
        model.places.filter { $0.kind == "ndi" }.map(\.title)
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
