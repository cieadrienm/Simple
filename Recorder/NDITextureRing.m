/*
 NDITextureRing.m
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

#import "NDITextureRing.h"

// How many frames a texture outlives. Six may be read at once: the latest, kept by its place to be shown and
// composed; three waiting in a MovieRecorder (kMaximumFramesPending); one read by each compositor's command buffer
// (the take's and the monitor's) until it completes. A frame waiting in the recorder is read within a frame or two,
// unless the GPU or the encoder lags: the six more give it about 100 ms at 60 fps to catch up. A texture written
// over too soon puts a later picture in a movie, unseen; a slot costs 8 MB at 1080p.
static const NSUInteger kTextureCount = 12;
// The largest side a texture can have
static const NSUInteger kLargestSide = 16384;

@implementation NDITextureRing {
    id<MTLDevice> _device;
    // No lock: the caller makes its calls one at a time. The textures themselves are read elsewhere, by other
    // threads and the GPU, but are not written to again until the ring comes round.
    id<MTLTexture> _textures[kTextureCount];
    // A view of each texture whose alpha reads as one, for pictures without alpha: made with the texture
    id<MTLTexture> _opaqueViews[kTextureCount];
    NSUInteger _next;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self)
    {
        _device = device;
    }
    return self;
}

- (id<MTLTexture>)textureWithBytes:(const void *)bytes
                             width:(NSUInteger)width
                            height:(NSUInteger)height
                       bytesPerRow:(NSUInteger)bytesPerRow
                          hasAlpha:(BOOL)hasAlpha
{
    // Metal reads rows which start on a multiple of 4 bytes only
    if (bytes == NULL || width == 0 || height == 0 || width > kLargestSide || height > kLargestSide || bytesPerRow < width * 4
        || bytesPerRow % 4 != 0)
    {
        return nil;
    }

    NSUInteger index = _next;
    id<MTLTexture> texture = _textures[index];
    if (texture == nil || texture.width != width || texture.height != height)
    {
        // A new one rather than the old one resized: whoever still holds the old one keeps its picture
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        // Written by the CPU, read by the GPU. Managed where memory is not shared (an Intel Mac's GPU):
        // replaceRegion: makes the GPU's copy follow.
        descriptor.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
        texture = [_device newTextureWithDescriptor:descriptor];
        id<MTLTexture> opaqueView = [texture newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               textureType:MTLTextureType2D
                                                                    levels:NSMakeRange(0, 1)
                                                                    slices:NSMakeRange(0, 1)
                                                                   swizzle:MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed,
                                                                                                         MTLTextureSwizzleGreen,
                                                                                                         MTLTextureSwizzleBlue,
                                                                                                         MTLTextureSwizzleOne)];
        if (texture == nil || opaqueView == nil)
        {
            _textures[index] = nil;
            _opaqueViews[index] = nil;
            return nil;
        }
        _textures[index] = texture;
        _opaqueViews[index] = opaqueView;
    }
    _next = (index + 1) % kTextureCount;

    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes bytesPerRow:bytesPerRow];
    return hasAlpha ? texture : _opaqueViews[index];
}

@end
