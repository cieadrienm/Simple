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

 A piece arrives when its last sample has been made: its place by our clock is its arrival less its duration. The
 stream is counted in whole samples of the pieces' rate.
 */
@interface SoundTimeline : NSObject
// origin: the time which is sample 0, on the clock of the times given below
- (instancetype)initWithOrigin:(NSTimeInterval)origin;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// The pieces to write for a piece which arrived at a time, in order, each following the last sample written: the
// piece itself; or silence then the piece when the stream is to catch up with the clock; or the piece less its first
// samples, or nothing, when the stream is ahead of it.
// The first piece of a run (the first, and the first after a change of sample rate) is placed exactly where it
// belongs. So is a piece more than 0.1 s from the stream's end: sound was away, or was left out. Closer than that,
// a single piece's arrival is no evidence (it jitters by tens of milliseconds): the error is smoothed over about two
// seconds of sound, and when it passes 0.02 s the stream is corrected by it, which keeps sound within about a frame
// of the pictures at the start and over hours.
// A piece which ends before the origin gives nothing.
// Silence comes in pieces of no more than 10 s (those of 10 s are one and the same, so that a long one costs one
// buffer). A time which is not a number, or which would place the piece more than 24 hours from the stream's end,
// is taken as wrong: it gives nothing and changes nothing.
- (NSArray<SourceSound *> *)piecesForSound:(SourceSound *)sound arrivedAtTime:(NSTimeInterval)time;
// Where the next sample goes, in seconds from the origin
@property (readonly) NSTimeInterval writtenDuration;
// Seconds of silence added and of sound left out so far
@property (readonly) NSTimeInterval silenceAdded;
@property (readonly) NSTimeInterval soundLeftOut;
@end

NS_ASSUME_NONNULL_END
