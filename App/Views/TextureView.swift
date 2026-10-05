/*
 TextureView.swift
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
import MetalKit
import RecorderKit

/// Shows the latest picture it is given, scaled to fit, on black, at the display's rate; ten times a second while
/// the display is limited (performance mode, during a take).
struct TextureView: NSViewRepresentable {
    let device: MTLDevice
    /// A stored value, so that SwiftUI sees it change and updates the view
    var isLimited = false
    /// The frame to show now, and whether its first row is the bottom of the picture. Called for each redraw.
    let frame: () -> (texture: MTLTexture?, flipped: Bool)

    func makeNSView(context: Context) -> FrameView {
        FrameView(device: device, isLimited: isLimited, frame: frame)
    }

    func updateNSView(_ view: FrameView, context: Context) {
        view.frameProvider = frame
        if view.isLimited != isLimited { view.isLimited = isLimited }
    }
}

final class FrameView: MTKView {
    var frameProvider: () -> (texture: MTLTexture?, flipped: Bool)
    /// Drawn RecorderLimitedDisplayRate times a second (the rate at which the recorder then composes what is shown)
    /// rather than at the display's
    var isLimited: Bool {
        didSet { preferredFramesPerSecond = isLimited ? Int(RecorderLimitedDisplayRate) : fullRate }
    }
    /// The display's own rate
    private let fullRate: Int
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex {
        float4 position [[position]];
        float2 texCoord;
    };
    vertex Vertex frameVertex(uint vertexID [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {
        Vertex out;
        out.position = float4(vertices[vertexID].xy, 0.0, 1.0);
        out.texCoord = vertices[vertexID].zw;
        return out;
    }
    fragment float4 frameFragment(Vertex in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        return float4(frame.sample(linear, in.texCoord).rgb, 1.0);
    }
    """

    init(device: MTLDevice, isLimited: Bool = false, frame: @escaping () -> (texture: MTLTexture?, flipped: Bool)) {
        frameProvider = frame
        // Drawn at the display's own rate, so that every picture of a source is shown: at half of it (as this was, to
        // leave the GPU to the encoders) a sixty-frame source visibly stutters. Performance mode chooses otherwise.
        fullRate = max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
        self.isLimited = isLimited
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        preferredFramesPerSecond = isLimited ? Int(RecorderLimitedDisplayRate) : fullRate
        queue = device.makeCommandQueue()
        if let library = try? device.makeLibrary(source: Self.shaders, options: nil) {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "frameVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "frameFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }

    required init(coder: NSCoder) {
        fatalError("FrameView is made in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue?.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let (texture, flipped) = frameProvider()
        if let texture, let pipeline, drawableSize.width > 0, drawableSize.height > 0 {
            let ratio = min(Float(drawableSize.width) / Float(texture.width), Float(drawableSize.height) / Float(texture.height))
            let width = Float(texture.width) * ratio / Float(drawableSize.width)
            let height = Float(texture.height) * ratio / Float(drawableSize.height)
            let top: Float = flipped ? 1 : 0, bottom: Float = 1 - top
            // x, y, u, v
            let vertices: [Float] = [-width, -height, 0, bottom,
                                     -width, height, 0, top,
                                     width, -height, 1, bottom,
                                     width, height, 1, top]
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(vertices, length: MemoryLayout<Float>.size * vertices.count, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
