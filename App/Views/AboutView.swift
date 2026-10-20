/*
 AboutView.swift
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

import AppKit
import SwiftUI

/// Simple Recorder ▸ About Simple Recorder: a dark window in the palette of the app and OSCScore.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show(model: RecorderModel, openHelp: @escaping () -> Void) {
        if let window {
            window.contentView = NSHostingView(rootView: AboutView(
                model: model,
                openHelp: { [weak window] in
                    window?.close()
                    openHelp()
                },
                close: { [weak window] in window?.close() }
            ))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingView(rootView: AboutView(
            model: model,
            openHelp: { [weak self] in
                self?.window?.close()
                openHelp()
            },
            close: { [weak self] in self?.window?.close() }
        ))
        let size = NSSize(width: 580, height: 400)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About \(SimpleRecorderApp.name)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x16 / 255.0, green: 0x19 / 255.0, blue: 0x1E / 255.0, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct AboutView: View {
    @ObservedObject var model: RecorderModel
    var openHelp: (() -> Void)? = nil
    var close: (() -> Void)? = nil

    @State private var copiedVersion = false

    private static let cyan = Color(hex: 0x5CE1E6)

    private struct FeatureCard: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String
    }

    private static let features: [FeatureCard] = [
        FeatureCard(
            id: "sources",
            icon: "rectangle.3.group.fill",
            tint: cyan,
            title: "Syphon & NDI Sources",
            detail: "Up to eight sources recorded on one clock — each to its own movie, assembled into one picture (Row, Column, Grid, Focus), or both."
        ),
        FeatureCard(
            id: "sound",
            icon: "waveform",
            tint: Theme.accent,
            title: "NDI & Computer Sound",
            detail: "48 kHz stereo audio in step with the pictures: each NDI source’s sound, or the Mac’s system audio via Core Audio process tap."
        ),
        FeatureCard(
            id: "gpu",
            icon: "cpu",
            tint: Theme.online,
            title: "GPU Encoding & Performance",
            detail: "Hardware H.264, HEVC, ProRes 422 and ProRes 4444 (with alpha). Performance mode limits the preview to 10 fps while recording."
        ),
        FeatureCard(
            id: "osc",
            icon: "antenna.radiowaves.left.and.right",
            tint: Theme.record,
            title: "OSC, OSCQuery & MCP Control",
            detail: "Remote control over UDP OSC and Bonjour OSCQuery, plus a bundled simple-recorder-mcp server for AI assistants."
        ),
    ]

    /// The version and build number when running from the app bundle, or `model.version` otherwise.
    var versionLabel: String {
        let v = model.version.isEmpty ? "dev" : model.version
        if v == "dev" { return "dev" }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty, !build.hasPrefix("@") {
            return "v\(v) (\(build))"
        }
        return "v\(v)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // MARK: Header
            HStack(alignment: .center, spacing: 18) {
                SimpleRecorderIconView(size: 68)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(SimpleRecorderApp.name)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        versionBadge
                    }
                    Text("Syphon, NDI & computer sound recorder for live performance")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    HStack(spacing: 8) {
                        statusPill(
                            icon: "dot.radiowaves.left.and.right",
                            text: model.oscPort > 0
                                ? "OSC :\(model.oscPort) · OSCQuery :\(model.oscQueryPort)"
                                : "OSC offline",
                            tint: model.oscPort > 0 ? Theme.online : Theme.textFaint
                        )
                        statusPill(
                            icon: "network",
                            text: model.ndiAvailable ? "NDI on" : "NDI off",
                            tint: model.ndiAvailable ? Theme.online : Theme.textFaint
                        )
                        statusPill(
                            icon: "sparkles.tv",
                            text: "Metal · Core Audio",
                            tint: Self.cyan
                        )
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            // MARK: Capabilities Grid
            VStack(alignment: .leading, spacing: 8) {
                Theme.sectionTitle("Capabilities & Engine")

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    ForEach(Self.features) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(item.tint)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(item.tint.opacity(0.14))
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(item.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(1.5)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.background)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                }
            }

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            // MARK: Footer
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adrien Mondot · cie Adrien M")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    Text("Syphon (BSD) · NDI® is a registered trademark of Vizrt NDI AB")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                if let openHelp {
                    Button("Help") { openHelp() }
                }
                if let close {
                    Button("OK") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 580)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var versionBadge: some View {
        Button {
            let line = "\(SimpleRecorderApp.name) \(versionLabel)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            copiedVersion = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copiedVersion = false
            }
        } label: {
            HStack(spacing: 5) {
                Text(versionLabel)
                    .font(Theme.mono(11, .semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: copiedVersion ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(copiedVersion ? Theme.online : Theme.textFaint)
                if copiedVersion {
                    Text("Copied")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.online)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Theme.accent.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Theme.accent.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Click to copy version to the clipboard")
    }

    private func statusPill(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textDim)
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

/// Draws the Simple Recorder icon (the Focus layout tiles in cyan and the red record light on a dark rounded tile),
/// identical to `Scripts/make-icon.swift`, so the About window always displays the crisp icon even outside the `.app`.
struct SimpleRecorderIconView: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height) / 1024
            func pt(_ x: CGFloat, _ yTopDown: CGFloat) -> CGPoint {
                CGPoint(x: x * s, y: yTopDown * s)
            }
            func rect(_ x: CGFloat, _ yBottomUp: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: (1024 - yBottomUp - h) * s, width: w * s, height: h * s)
            }

            let bodyRect = rect(100, 100, 824, 824)
            let bodyPath = Path(roundedRect: bodyRect, cornerRadius: 186 * s)
            context.fill(
                bodyPath,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x232833), Color(hex: 0x0F1115)]),
                    startPoint: pt(0, 100),
                    endPoint: pt(0, 924)
                )
            )

            let cyan = Color(hex: 0x5CE1E6)
            let gap: CGFloat = 34, stroke: CGFloat = 30, radius: CGFloat = 46
            let left: CGFloat = 196, right: CGFloat = 828, top: CGFloat = 736, bottom: CGFloat = 364
            let split = left + (right - left - gap) * 0.64
            let middle = (top + bottom) / 2
            let tiles = [
                rect(left, bottom, split - left, top - bottom),
                rect(split + gap, middle + gap / 2, right - split - gap, top - middle - gap / 2),
                rect(split + gap, bottom, right - split - gap, middle - gap / 2 - bottom),
            ]
            for tile in tiles {
                let tilePath = Path(roundedRect: tile, cornerRadius: radius * s)
                context.fill(
                    tilePath,
                    with: .linearGradient(
                        Gradient(colors: [cyan.opacity(0.34), cyan.opacity(0.04)]),
                        startPoint: CGPoint(x: 0, y: tile.minY),
                        endPoint: CGPoint(x: 0, y: tile.maxY + 80 * s)
                    )
                )
                let strokeRect = tile.insetBy(dx: stroke * s / 2, dy: stroke * s / 2)
                let strokePath = Path(roundedRect: strokeRect, cornerRadius: (radius - stroke / 2) * s)
                context.stroke(strokePath, with: .color(cyan), lineWidth: stroke * s)
            }

            // Record light at (744, 306) in bottom-up coordinates
            let r: CGFloat = 98
            let lightRect = rect(744 - r, 306 - r, r * 2, r * 2)
            context.fill(Path(ellipseIn: lightRect.insetBy(dx: -36 * s, dy: -36 * s)), with: .color(Color(hex: 0x12151A)))
            context.fill(Path(ellipseIn: lightRect), with: .color(Color(hex: 0xFF5C57)))
            context.stroke(Path(ellipseIn: lightRect.insetBy(dx: -10 * s, dy: -10 * s)), with: .color(.white), lineWidth: 20 * s)

            let rimRect = bodyRect.insetBy(dx: 2 * s, dy: 2 * s)
            context.stroke(Path(roundedRect: rimRect, cornerRadius: 184 * s), with: .color(.white.opacity(0.10)), lineWidth: 4 * s)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 3)
    }
}
