/*
 NDITestSender.h
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
#import "NDILibrary.h"

NS_ASSUME_NONNULL_BEGIN

// A sender made through the library, under a name of its own, which sends a picture at a rate on its own thread
@interface NDITestSender : NSObject

// nil if the library is not available: the test is then skipped (XCTSkip), not failed
- (nullable instancetype)initWithLibrary:(NDILibrary *)library name:(NSString *)name;
- (instancetype)init NS_UNAVAILABLE;

// The picture sent from now on: one colour (blue, green, red, alpha), an orange top left quarter if marked.
// hasAlpha NO sends BGRX, with alpha as the fourth byte all the same. padding: bytes added to each row.
- (void)sendWidth:(int)width height:(int)height colour:(const uint8_t *)bgra marked:(BOOL)marked
         hasAlpha:(BOOL)hasAlpha padding:(int)padding framesPerSecond:(int)framesPerSecond
    NS_SWIFT_NAME(send(width:height:colour:marked:hasAlpha:padding:framesPerSecond:));

// Sound sent from now on beside the picture, from a thread of its own, in pieces of 20 ms of planar floats, clocked by
// NDI: a sine of a frequency (half scale; channel n, from 0, at frequency × (n + 1)), or silence with a click (one
// full-scale pulse of 5 ms on every channel) each time -click is called. Channels 1, 2 or 4; any rate.
- (void)sendToneOfFrequency:(double)frequency channelCount:(int)channels sampleRate:(int)rate
    NS_SWIFT_NAME(sendTone(frequency:channelCount:sampleRate:));
- (void)sendSilenceWithClicksOfChannelCount:(int)channels sampleRate:(int)rate
    NS_SWIFT_NAME(sendSilenceWithClicks(channelCount:sampleRate:));
// A click now, at the start of the next piece of sound, and — if the picture is marked — the whole picture white for
// the next picture sent. Each thread takes it when it next sends: the two may be a piece of sound and a picture apart.
// The time between the two sends is logged.
- (void)click;
// Stops the sound, and returns once no more is sent; pictures go on
- (void)stopSound;

// Stops sending and destroys the sender. Call it: the sending thread keeps the sender alive until then
- (void)stop;

// The source as NDI describes it ("HOST (Test …)"), and its address, nil when NDI gives none (NDI 6.1.1 gives none
// for a sender: a receiver given the name alone finds it): what a receiver connects to without a finder
@property (readonly, copy) NSString *sourceName;
@property (readonly, nullable, copy) NSString *sourceURL;

// A raw find + recv through the library's table: the size of the first video frame of the source whose name ends with
// "(name)", zero if none arrives within the timeout (finding included)
+ (NSSize)receiveOneFrameNamed:(NSString *)name library:(NDILibrary *)library timeout:(NSTimeInterval)timeout
    NS_SWIFT_NAME(receiveOneFrame(named:library:timeout:));

// The same without a finder: the receiver connects to the source's name and address (nil: the name alone)
+ (NSSize)receiveOneFrameFromSource:(NSString *)sourceName url:(nullable NSString *)url library:(NDILibrary *)library
                            timeout:(NSTimeInterval)timeout
    NS_SWIFT_NAME(receiveOneFrame(fromSource:url:library:timeout:));

@end

NS_ASSUME_NONNULL_END
