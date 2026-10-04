/*
 NDITextureRing.h
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

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/*
 Copies pictures given as bytes into Metal textures. The textures come from a ring: one returned is not written
 to again by the eleven calls which follow, so that it can wait to be shown, composed and encoded. A texture still
 held when the size changes is not reused: it keeps its picture.
 */
@interface NDITextureRing : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
// bytes: BGRA, the first row at the top, rows of bytesPerRow bytes (at least width × 4).
// hasAlpha NO: the fourth byte of each pixel is not alpha; the texture returned reads as opaque.
// nil if width or height is 0 or above 16384, or bytesPerRow is too short. One thread at a time.
- (nullable id<MTLTexture>)textureWithBytes:(const void *)bytes
                                      width:(NSUInteger)width
                                     height:(NSUInteger)height
                                bytesPerRow:(NSUInteger)bytesPerRow
                                   hasAlpha:(BOOL)hasAlpha;
@end

NS_ASSUME_NONNULL_END
