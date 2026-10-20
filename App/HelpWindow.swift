/*
 HelpWindow.swift
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
import WebKit

/// Help ▸ Simple Recorder Help: the bundled HTML guide (`Resources/Help`) in a window of its own.
@MainActor
final class HelpWindowController: NSObject, WKNavigationDelegate {
    static let shared = HelpWindowController()
    private var window: NSWindow?
    private var webView: WKWebView?

    /// In the app bundle, or in the repository when run with `swift run` or `swift test`.
    static var root: URL {
        Bundle.main.url(forResource: "Help", withExtension: nil)
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Help")
    }

    var isVisible: Bool { window?.isVisible == true }
    var currentURL: URL? { webView?.url }

    /// Opens (or brings back) the guide, at `section` when given (`"dispositions"`, `"son"`, `"osc"`…).
    func show(section: String? = nil, version: String = "dev") {
        let page = Self.root.appendingPathComponent("index.html")
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        let resolvedVersion = version.isEmpty ? "dev" : version
        components.queryItems = [URLQueryItem(name: "v", value: resolvedVersion)]
        components.fragment = section
        let url = components.url ?? page
        if let window, let webView {
            if let section {
                webView.evaluateJavaScript("location.hash = '\(section)'")
            } else if webView.url == nil {
                webView.loadFileURL(url, allowingReadAccessTo: Self.root)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1040, height: 760))
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // no white flash before the dark page paints
        webView.loadFileURL(url, allowingReadAccessTo: Self.root)
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(SimpleRecorderApp.name) Help"
        window.contentView = webView
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x11 / 255.0, green: 0x13 / 255.0, blue: 0x17 / 255.0, alpha: 1)
        window.minSize = CGSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SimpleRecorderHelp")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.webView = webView
    }

    /// Links to the web open in the browser; the guide's own pages stay here.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }
}
