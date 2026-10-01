/*
 SimpleImageView.m
 Syphon (SDK)

 Copyright 2010-2014 bangnoise (Tom Butterworth) & vade (Anton Marini).
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

#import "SimpleImageView.h"

@interface SimpleImageView ()
@property (readwrite, strong) NSError *error;
@end

static NSString * const kShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct Vertex {\n\
    float4 position [[position]];\n\
    float2 texCoord;\n\
};\n\
vertex Vertex imageVertex(uint vertexID [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {\n\
    Vertex out;\n\
    out.position = float4(vertices[vertexID].xy, 0.0, 1.0);\n\
    out.texCoord = vertices[vertexID].zw;\n\
    return out;\n\
}\n\
fragment float4 imageFragment(Vertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {\n\
    constexpr sampler linear(filter::linear, address::clamp_to_edge);\n\
    return image.sample(linear, in.texCoord);\n\
}\n";

@implementation SimpleImageView {
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    self.device = MTLCreateSystemDefaultDevice();
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    // Draw on demand: a new frame or a change in size marks the view as needing display
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;

    NSError *error = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:kShaderSource options:nil error:&error];
    if (library)
    {
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = [library newFunctionWithName:@"imageVertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"imageFragment"];
        descriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat;
        _pipeline = [self.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    }
    _commandQueue = [self.device newCommandQueue];

    if (_pipeline == nil || _commandQueue == nil)
    {
        self.error = error ?: [NSError errorWithDomain:@"info.v002.Syphon.Simple.error"
                                                  code:-1
                                              userInfo:@{NSLocalizedDescriptionKey: @"Metal Error"}];
    }
}

- (NSSize)renderSize
{
    return self.drawableSize;
}

- (void)drawRect:(NSRect)dirtyRect
{
    MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = self.currentDrawable;
    if (pass == nil || drawable == nil)
    {
        return;
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];

    id<MTLTexture> image = self.image;
    NSSize frameSize = self.drawableSize;
    if (image && _pipeline && frameSize.width > 0 && frameSize.height > 0)
    {
        // Scale to fit: when the view is aspect-restrained, these will always be 1.0
        float ratio = MIN(frameSize.width / image.width, frameSize.height / image.height);
        float width = image.width * ratio / frameSize.width;
        float height = image.height * ratio / frameSize.height;
        float top = self.imageIsFlipped ? 1.0 : 0.0;
        float bottom = 1.0 - top;

        // x, y, u, v
        const float vertices[] = {
            -width, -height, 0.0, bottom,
            -width,  height, 0.0, top,
             width, -height, 1.0, bottom,
             width,  height, 1.0, top
        };

        [encoder setRenderPipelineState:_pipeline];
        [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
        [encoder setFragmentTexture:image atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
