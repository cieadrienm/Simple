/*
    SimpleRenderer.m
	Syphon (SDK)
	
    Copyright 2010-2011 bangnoise (Tom Butterworth) & vade (Anton Marini).
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

#import "SimpleRenderer.h"

typedef struct {
    float width;
    float height;
    float level;
    float bar;
} SimpleRendererUniforms;

static NSString * const kShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct Uniforms {\n\
    float2 size;\n\
    float level;\n\
    float bar;\n\
};\n\
vertex float4 animationVertex(uint vertexID [[vertex_id]]) {\n\
    // A single triangle which covers the whole frame\n\
    float2 position = float2((vertexID << 1) & 2, vertexID & 2);\n\
    return float4(position * 2.0 - 1.0, 0.0, 1.0);\n\
}\n\
fragment float4 animationFragment(float4 position [[position]], constant Uniforms &uniforms [[buffer(0)]]) {\n\
    float2 uv = position.xy / uniforms.size;\n\
    // A pulsing background, darker towards the bottom...\n\
    float3 color = float3(uniforms.level * (1.0 - 0.5 * uv.y));\n\
    // ...a bar which sweeps from left to right, so dropped or repeated frames are easy to see...\n\
    if (abs(uv.x - uniforms.bar) < 0.01) color = float3(1.0);\n\
    // ...and a marker in the top left corner, so the orientation of the frame is obvious\n\
    float marker = 0.1 * min(uniforms.size.x, uniforms.size.y);\n\
    if (position.x < marker && position.y < marker) color = float3(1.0, 0.5, 0.0);\n\
    return float4(color, 1.0);\n\
}\n";

@implementation SimpleRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self)
    {
        _device = device;

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:nil error:&error];
        if (library)
        {
            MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
            descriptor.vertexFunction = [library newFunctionWithName:@"animationVertex"];
            descriptor.fragmentFunction = [library newFunctionWithName:@"animationFragment"];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        }
        if (_pipeline == nil)
        {
            NSLog(@"SimpleRenderer could not be created: %@", error);
            return nil;
        }
    }
    return self;
}

- (id<MTLTexture>)renderFrameOfSize:(NSSize)dimensions onCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
    NSUInteger width = MAX(dimensions.width, 1);
    NSUInteger height = MAX(dimensions.height, 1);

    if (_texture.width != width || _texture.height != height)
    {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        _texture = [_device newTextureWithDescriptor:descriptor];
    }

    NSTimeInterval time = [NSDate timeIntervalSinceReferenceDate];
    SimpleRendererUniforms uniforms = {
        .width = width,
        .height = height,
        // The background pulses every four seconds, the bar crosses the frame every two
        .level = 0.4 * (1.2 + sin(2.0 * M_PI * time / 4.0)),
        .bar = fmod(time, 2.0) / 2.0
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = _texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    return _texture;
}
@end
