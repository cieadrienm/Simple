/*
 Compositor.h
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
#import "Layout.h"

NS_ASSUME_NONNULL_BEGIN

/*
 Draws sources into one picture, each in the place a layout gives it.
 */
@interface Compositor : NSObject
// The compositor draws with this queue, on its device
- (instancetype)initWithCommandQueue:(id<MTLCommandQueue>)queue;

// Draws the sources into a texture of the layout's size, and returns it.
// textures: one for each source of the layout; NSNull for a source with no picture, whose place stays empty.
// flipped: for each source, YES if its texture's first row is the bottom of its picture.
// transparent: the picture is transparent where there is no source, and a source's own transparency is kept.
//   Otherwise it is black there, and opaque everywhere.
// The texture returned is not drawn to again by the three calls which follow: it can wait to be encoded while the
// next pictures are composed. nil if the textures are not as many as the layout's sources.
// Can be called from any thread.
- (nullable id<MTLTexture>)compose:(Layout *)layout
                          textures:(NSArray *)textures
                           flipped:(NSArray<NSNumber *> *)flipped
                       transparent:(BOOL)transparent;
@end

NS_ASSUME_NONNULL_END
