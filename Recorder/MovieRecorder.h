/*
 MovieRecorder.h
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

typedef NS_ENUM(NSInteger, MovieCodec) {
    MovieCodecH264,
    MovieCodecHEVC,
    MovieCodecProRes422,
    MovieCodecProRes4444
};

extern NSString * const MovieRecorderErrorDomain;

@interface MovieRecorderSettings : NSObject <NSCopying>
@property (assign) MovieCodec codec;
// The size of the movie. If either is 0, the size of the first frame is used.
@property (assign) NSInteger width;
@property (assign) NSInteger height;
// The most frames the movie has each second. 0 keeps every frame.
@property (assign) double framesPerSecond;
// For H.264 and HEVC. 0 chooses a bitrate from the movie's size and frame rate.
@property (assign) double megabitsPerSecond;
// "h264", "hevc", "prores422", "prores4444"
+ (NSArray<NSString *> *)codecNames;
+ (NSString *)nameForCodec:(MovieCodec)codec;
+ (BOOL)getCodec:(MovieCodec *)codec forName:(NSString *)name;
@end

/*
 Writes Metal textures to a QuickTime movie as they arrive.

 Frames are scaled to fit the movie's size on the GPU and encoded away from the caller's thread. If the encoder cannot
 keep up frames are dropped rather than delaying the caller.
 */
@interface MovieRecorder : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
// Fails if a recording is in progress, if the file exists or if it could not be created in its folder.
- (BOOL)startWritingToURL:(NSURL *)url settings:(MovieRecorderSettings *)settings error:(NSError **)error;
// Can be called from any thread, and returns at once.
// flipped: the first row of the texture is the bottom of the picture, as it is for Syphon frames.
// time: when the frame arrived, in seconds, on the clock also used for finishAtTime:completionHandler:
- (void)appendTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped atTime:(NSTimeInterval)time;
// Stops accepting frames, waits for those being encoded, and finishes the file so that the movie lasts until time.
// handler is called on the main queue, with an error if the movie could not be written. If no frame was received
// there is no file, and that is reported as an error.
- (void)finishAtTime:(NSTimeInterval)time completionHandler:(void (^)(NSError * _Nullable error))handler;
@property (readonly, getter=isRecording) BOOL recording;
@property (readonly) NSUInteger framesWritten;
// Frames discarded because the encoder could not keep up
@property (readonly) NSUInteger framesDropped;
// Frames accepted which are not yet written or dropped
@property (readonly) NSUInteger framesPending;
// The size of the movie: zero until the first frame has arrived
@property (readonly) NSSize outputSize;
// Called on the main queue if writing fails. The recorder has then stopped recording.
@property (copy, nullable) void (^failureHandler)(NSError *error);
@end

NS_ASSUME_NONNULL_END
