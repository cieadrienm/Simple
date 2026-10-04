/*
 TakeBar.swift
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

/// The take: the record button, the time recorded, what is being written.
struct TakeBar: View {
    @ObservedObject var model: RecorderModel

    var body: some View {
        HStack(spacing: 14) {
            RecordButton(isRecording: model.isRecording) { model.toggleRecording() }
                .help(model.isRecording ? "Stop recording and finish the movies (\u{2318}R)" : "Record the sources chosen (\u{2318}R)")
            Text(TimeFormat.clock(model.elapsed))
                .font(Theme.mono(26, .medium))
                .foregroundStyle(model.isRecording ? Theme.text : Theme.textDim)
            caption
            Spacer()
            // What the next take writes: it cannot change during one
            Picker("", selection: Binding(get: { model.output }, set: { model.setOutput($0) })) {
                ForEach(RecorderModel.outputs, id: \.name) { Text($0.title).tag($0.name) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
            .disabled(model.isRecording)
            .help("A movie for each source, one movie of the sources assembled, or both")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.panel)
    }

    @ViewBuilder private var caption: some View {
        switch TakeCaption.of(state: model.state, notice: model.notice, failure: model.failure, frames: model.frames, dropped: model.dropped, soundLost: model.soundLeftOut) {
        case .none:
            EmptyView()
        case .notice(let notice):
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent).font(.system(size: 12)).lineLimit(2)
        case .failure(let failure):
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.record).font(.system(size: 12)).lineLimit(2)
        case .finishing:
            Text("Finishing the movies\u{2026}").font(.system(size: 12)).foregroundStyle(Theme.textDim)
        case .progress(let frames, let dropped, let soundLost):
            HStack(spacing: 0) {
                Text("\(frames) frames \u{00B7} \(dropped) dropped")
                    .foregroundStyle(dropped > 0 ? Theme.accent : Theme.textDim)
                if soundLost > 0 {
                    Text(" \u{00B7} \(TakeCaption.soundLostText(soundLost)) of sound lost").foregroundStyle(Theme.accent)
                }
            }
            .font(Theme.mono(12))
        }
    }
}

/// What is said beside the time.
enum TakeCaption: Equatable {
    case none
    /// An error which has just happened: a refused message, a recording which could not start
    case notice(String)
    /// Why a recording ended, or why one of its movies has stopped while the others go on
    case failure(String)
    case finishing
    case progress(frames: Int, dropped: Int, soundLost: Double)

    static func of(state: String, notice: String, failure: String, frames: Int, dropped: Int, soundLost: Double = 0) -> TakeCaption {
        if !notice.isEmpty { return .notice(notice) }
        // A movie which has failed while the take goes on must stay in sight for as long as it does: nobody is
        // watching at the moment it happens
        if !failure.isEmpty { return .failure(failure) }
        switch state {
        case "recording": return .progress(frames: frames, dropped: dropped, soundLost: soundLost)
        case "finishing": return .finishing
        default: return .none
        }
    }

    /// Seconds of sound lost, said briefly: "0.4 s", "3.0 s", "12 s"; empty when none was
    static func soundLostText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        return seconds < 10 ? String(format: "%.1f s", seconds) : String(format: "%.0f s", seconds)
    }
}

/// Stays pressed, and shows a stop square, for as long as a recording is in progress — whatever started it.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Theme.record : Color.clear)
                    .overlay(Circle().strokeBorder(Theme.record, lineWidth: 2))
                if isRecording {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 12, height: 12)
                } else {
                    Circle().fill(Theme.record).frame(width: 14, height: 14)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
    }
}
