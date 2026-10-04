/*
 SoundTimeline.h
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

@class SourceSound;

NS_ASSUME_NONNULL_BEGIN

/*
 Places pieces of sound, which arrive at moments of our clock but were made on their source's, in one unbroken
 stream of samples which begins at the track's zero.

 A piece arrives when its last sample has been made: its place by our clock is its arrival less its duration. While
 the stream's end is within 0.1 s of that place the piece simply follows; beyond it, the stream is brought back
 exactly onto the clock, with silence or by leaving sound out. The stream is counted in whole samples of the
 pieces' rate.
 */
@interface SoundTimeline : NSObject
// origin: the time which is sample 0, on the clock of the times given below
- (instancetype)initWithOrigin:(NSTimeInterval)origin;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// The pieces to write for a piece which arrived at a time, in order, each following the last sample written:
// usually the piece itself; silence then the piece when sound is late by more than the tolerance (it starts late,
// it was away, it was left out); the piece less its first samples, or nothing, when it is early by more.
// A piece which ends before the origin gives nothing. A change of sample rate starts a new run at the time given.
// Silence comes in pieces of no more than 10 s.
- (NSArray<SourceSound *> *)piecesForSound:(SourceSound *)sound arrivedAtTime:(NSTimeInterval)time;
// Where the next sample goes, in seconds from the origin
@property (readonly) NSTimeInterval writtenDuration;
// Seconds of silence added and of sound left out so far
@property (readonly) NSTimeInterval silenceAdded;
@property (readonly) NSTimeInterval soundLeftOut;
@end

NS_ASSUME_NONNULL_END
