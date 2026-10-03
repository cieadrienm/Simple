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

/// The sources chosen, as they arrive. (The assembled picture takes this place when there is one.)
struct MonitorView: View {
    @ObservedObject var model: RecorderModel
    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            if model.places.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 28)).foregroundStyle(Theme.textFaint)
                    Text("Tick a source to record it").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    Text("Syphon servers appear on the left as their applications start.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let count = model.places.count
                let columns = Int(ceil(sqrt(Double(count))))
                let rows = Int(ceil(Double(count) / Double(columns)))
                let width = (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                let height = (geometry.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                if index < count {
                                    tile(index).frame(width: max(width, 1), height: max(height, 1))
                                } else {
                                    Color.clear.frame(width: max(width, 1), height: max(height, 1))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.background)
    }

    private func tile(_ index: Int) -> some View {
        let place = model.places[index]
        let controller = model.controller
        return ZStack(alignment: .bottomLeading) {
            // The place is looked up at each redraw: places move, and their frames change sixty times a second
            TextureView(device: controller.device) {
                let places = controller.places
                guard index < places.count else { return (nil, false) }
                return (places[index].latestFrame, places[index].flipped)
            }
            if !place.isOnline {
                Text(place.width > 0 ? "Away" : "Waiting for \(place.title)")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.6))
            }
            HStack(spacing: 5) {
                Circle().fill(place.isOnline ? Theme.online : Theme.textFaint).frame(width: 6, height: 6)
                Text(place.title).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
