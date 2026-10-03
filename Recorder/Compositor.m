/*
 Compositor.m
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

#import "Compositor.h"

// How many pictures there are to draw to in turn: one more than can be waiting to be encoded
static const NSUInteger kTargets = 4;
// The largest picture Metal can hold, on a side
static const CGFloat kLargestSide = 16384;

static NSString * const kShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct Vertex {\n\
    float4 position [[position]];\n\
    float2 texCoord;\n\
};\n\
vertex Vertex sourceVertex(uint vertexID [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {\n\
    Vertex out;\n\
    out.position = float4(vertices[vertexID].xy, 0.0, 1.0);\n\
    out.texCoord = vertices[vertexID].zw;\n\
    return out;\n\
}\n\
fragment float4 sourceFragment(Vertex in [[stage_in]], texture2d<float> source [[texture(0)]], constant float &opaque [[buffer(0)]]) {\n\
    constexpr sampler linear(filter::linear, address::clamp_to_edge);\n\
    float4 colour = source.sample(linear, in.texCoord);\n\
    // A source replaces what is under it: nothing is blended\n\
    return float4(colour.rgb, max(colour.a, opaque));\n\
}\n";

@implementation Compositor {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    // One call at a time: guards the targets
    NSLock *_lock;
    id<MTLTexture> _targets[kTargets];
    NSUInteger _next;
}

- (instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue
{
    self = [super init];
    if (self)
    {
        _queue = queue;
        _lock = [[NSLock alloc] init];

        NSError *error = nil;
        id<MTLLibrary> library = [queue.device newLibraryWithSource:kShaderSource options:nil error:&error];
        if (library)
        {
            MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
            descriptor.vertexFunction = [library newFunctionWithName:@"sourceVertex"];
            descriptor.fragmentFunction = [library newFunctionWithName:@"sourceFragment"];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            _pipeline = [queue.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        }
        if (_pipeline == nil)
        {
            NSLog(@"Compositor could not be created: %@", error);
            return nil;
        }
    }
    return self;
}

// The next picture to draw to, of this size
- (id<MTLTexture>)targetOfWidth:(NSUInteger)width height:(NSUInteger)height
{
    id<MTLTexture> target = _targets[_next];
    if (target == nil || target.width != width || target.height != height)
    {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        target = [_queue.device newTextureWithDescriptor:descriptor];
        _targets[_next] = target;
    }
    _next = (_next + 1) % kTargets;
    return target;
}

- (id<MTLTexture>)compose:(Layout *)layout
                 textures:(NSArray *)textures
                  flipped:(NSArray<NSNumber *> *)flipped
              transparent:(BOOL)transparent
{
    return [self compose:layout textures:textures flipped:flipped transparent:transparent completionHandler:nil];
}

- (id<MTLTexture>)compose:(Layout *)layout
                 textures:(NSArray *)textures
                  flipped:(NSArray<NSNumber *> *)flipped
              transparent:(BOOL)transparent
        completionHandler:(void (^)(id<MTLTexture> picture))handler
{
    NSArray<NSValue *> *frames = layout.frames;
    NSSize size = layout.size;
    if (textures.count != frames.count || flipped.count != frames.count || size.width < 1.0 || size.height < 1.0)
    {
        return nil;
    }
    if (size.width > kLargestSide || size.height > kLargestSide)
    {
        // No texture can be that large
        return nil;
    }

    [_lock lock];
    id<MTLTexture> target = [self targetOfWidth:(NSUInteger)size.width height:(NSUInteger)size.height];
    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    if (target == nil || commandBuffer == nil)
    {
        [_lock unlock];
        return nil;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, transparent ? 0.0 : 1.0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    float opaque = transparent ? 0.0 : 1.0;
    [encoder setFragmentBytes:&opaque length:sizeof(opaque) atIndex:0];
    for (NSUInteger index = 0; index < frames.count; index++)
    {
        id texture = textures[index];
        if (![texture conformsToProtocol:@protocol(MTLTexture)])
        {
            continue;
        }
        // The source's rectangle, from pixels counted from the top left to Metal's coordinates, where y goes up
        NSRect frame = frames[index].rectValue;
        // A source which is no longer the shape of its place (its window was resized after the layout was made)
        // is fitted in it, centred, rather than stretched
        CGFloat width = [texture width], height = [texture height];
        CGFloat fitted = NSHeight(frame) * width / height;
        if (fitted < NSWidth(frame) - 1.0)
        {
            frame = NSMakeRect(NSMinX(frame) + floor((NSWidth(frame) - fitted) / 2.0), NSMinY(frame), round(fitted), NSHeight(frame));
        }
        else if (fitted > NSWidth(frame) + 1.0)
        {
            CGFloat fittedHeight = NSWidth(frame) * height / width;
            frame = NSMakeRect(NSMinX(frame), NSMinY(frame) + floor((NSHeight(frame) - fittedHeight) / 2.0), NSWidth(frame), round(fittedHeight));
        }
        float left = NSMinX(frame) / size.width * 2.0 - 1.0, right = NSMaxX(frame) / size.width * 2.0 - 1.0;
        float top = 1.0 - NSMinY(frame) / size.height * 2.0, bottom = 1.0 - NSMaxY(frame) / size.height * 2.0;
        float topV = flipped[index].boolValue ? 1.0 : 0.0, bottomV = 1.0 - topV;
        // x, y, u, v
        const float vertices[] = {
            left,  bottom, 0.0, bottomV,
            left,  top,    0.0, topV,
            right, bottom, 1.0, bottomV,
            right, top,    1.0, topV
        };
        [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
        [encoder setFragmentTexture:texture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
    if (handler)
    {
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            handler(target);
        }];
    }
    [commandBuffer commit];
    [_lock unlock];
    return target;
}

@end
