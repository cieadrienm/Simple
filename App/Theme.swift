/*
 Theme.swift
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

/// One dark palette, the one of OSCScore.
enum Theme {
    static let background = Color(hex: 0x111317)
    static let panel = Color(hex: 0x16191E)
    static let field = Color(hex: 0x1F2530)
    static let separator = Color(hex: 0x0B0C0F)
    static let text = Color(hex: 0xE6E8EC)
    static let textDim = Color(hex: 0x8A919E)
    static let textFaint = Color(hex: 0x565D6A)
    static let accent = Color(hex: 0xFFB454)
    static let record = Color(hex: 0xFF5C57)
    static let online = Color(hex: 0x9ECE6A)

    /// Small capitals over a group of controls, as in OSCScore's side panels
    static func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .kerning(1.1)
            .foregroundStyle(textFaint)
    }

    /// Figures which do not jump about as they change
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension Color {
    init(hex: Int) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

enum TimeFormat {
    /// `m:ss`, or `h:mm:ss` past the hour
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
