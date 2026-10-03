/*
 FrameSource.h
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

typedef NS_ENUM(NSInteger, FrameSourceKind) {
    FrameSourceKindSyphon,
    FrameSourceKindNDI
};

/*
 Something which can be recorded, as it is listed.
 */
@interface SourceDescription : NSObject
// What it is called, in the window and in OSC. A source is known by its title.
@property (readonly, copy) NSString *title;
// Where it comes from: its application, or "NDI"
@property (readonly, copy) NSString *detail;
@property (readonly) FrameSourceKind kind;
- (instancetype)initWithTitle:(NSString *)title detail:(NSString *)detail kind:(FrameSourceKind)kind;
@end

/*
 A source which is connected to: it delivers its frames until it is stopped.
 */
@protocol FrameSource <NSObject>
@property (readonly, copy) NSString *title;
// YES if the first row of its textures is the bottom of the picture, as it is for Syphon
@property (readonly) BOOL flipped;
// Called for every frame, on any thread
@property (copy, nullable) void (^frameHandler)(id<MTLTexture> frame);
- (void)stop;
@end

/*
 The sources which exist. Used on the main thread.
 */
@protocol SourceDirectory <NSObject>
- (NSArray<SourceDescription *> *)availableSources;
// Connects to the source with this title. nil if there is none.
- (nullable id<FrameSource>)connectToSourceWithTitle:(NSString *)title device:(id<MTLDevice>)device;
// Called on the main queue when availableSources has changed
@property (copy, nullable) void (^changeHandler)(void);
@end

NS_ASSUME_NONNULL_END
