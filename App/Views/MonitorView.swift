/*
 MonitorView.swift
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

/// The assembled picture, as it is (or would be) recorded, with each source's title over its part; under it, the
/// layout and the picture's size. With "Separate" it is still shown: it is how the sources are watched.
struct MonitorView: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        VStack(spacing: 10) {
            if model.places.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 28)).foregroundStyle(Theme.textFaint)
                    Text("Tick a source to record it").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    Text("Syphon servers appear on the left as their applications start.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    picture(in: geometry.size)
                }
                HStack(spacing: 10) {
                    LayoutPicker(layout: model.layout, isEnabled: !model.isRecording) { model.setLayout($0) }
                    Spacer()
                    if model.pictureIsTooLarge {
                        Label("Too large to be recorded", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    Text(verbatim: "\(Int(model.pictureSize.width)) \u{00D7} \(Int(model.pictureSize.height))")
                        .font(Theme.mono(11)).foregroundStyle(model.pictureIsTooLarge ? Theme.accent : Theme.textDim)
                        .help("The size of the assembled picture")
                }
            }
        }
        .padding(12)
        .background(Theme.background)
    }

    /// The picture fitted in the space there is, and the titles over it.
    private func picture(in space: CGSize) -> some View {
        let size = model.pictureSize
        let ratio = size.width > 0 && size.height > 0 ? min(space.width / size.width, space.height / size.height) : 0
        let fitted = CGSize(width: max(size.width * ratio, 1), height: max(size.height * ratio, 1))
        let controller = model.controller
        return ZStack(alignment: .topLeading) {
            // The picture is asked for at each redraw: it changes sixty times a second
            TextureView(device: controller.device) { (controller.assembledFrame, false) }
            ForEach(Array(zip(model.places.indices, model.titleRects)), id: \.0) { index, rect in
                title(model.places[index])
                    .frame(maxWidth: max(rect.width * fitted.width - 8, 20), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: rect.minX * fitted.width + 4, y: rect.minY * fitted.height + 4)
            }
        }
        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func title(_ place: RecorderModel.Place) -> some View {
        HStack(spacing: 5) {
            Circle().fill(place.isOnline ? Theme.online : Theme.textFaint).frame(width: 6, height: 6)
            Text(place.title).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
            if !place.isOnline {
                // A source which was never seen is waited for; one which was has gone, or its picture does not move
                Text(place.width > 0 ? "Away" : "Waiting").font(.system(size: 10)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The four layouts, as a row of pictures of them.
struct LayoutPicker: View {
    let layout: String
    let isEnabled: Bool
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(RecorderModel.layouts, id: \.name) { item in
                Button { choose(item.name) } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(item.name == layout ? Theme.text : Theme.textDim)
                        .frame(width: 34, height: 24)
                        .background(item.name == layout ? Theme.field : Theme.panel)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
    }
}
