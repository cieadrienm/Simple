/*
 SourceSound.h
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

NS_ASSUME_NONNULL_BEGIN

/*
 A piece of sound: two channels of floating-point samples, interleaved (left, right, left…).

 It owns a copy of its samples and never changes: it can be handed from one thread to another.
 */
@interface SourceSound : NSObject
// planes: channelCount pointers to frameCount floats each (as NDI gives them: stride in bytes between planes).
// One channel is copied to both; of more than two the first two are kept. nil if there is nothing to keep, if the
// rate is not a positive number, or if the stride (of several channels) is shorter than a plane or not a whole
// number of floats.
+ (nullable instancetype)soundWithPlanarSamples:(const float *_Nullable)samples
                                   channelCount:(NSUInteger)channelCount
                                     frameCount:(NSUInteger)frameCount
                           channelStrideInBytes:(NSUInteger)stride
                                     sampleRate:(double)sampleRate;
// Interleaved stereo, as tests and the timeline make it
+ (nullable instancetype)soundWithInterleavedStereoSamples:(const float *_Nullable)samples
                                                frameCount:(NSUInteger)frameCount
                                                sampleRate:(double)sampleRate;
// sampleRate must be a positive number
+ (instancetype)silenceOfFrameCount:(NSUInteger)frameCount sampleRate:(double)sampleRate;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property (readonly) double sampleRate;         // of the source: 48000, 44100…
@property (readonly) NSUInteger frameCount;     // samples in each channel
@property (readonly) const float *samples;      // frameCount × 2 floats
@property (readonly) NSTimeInterval duration;
// The frames from one index on (nil if none is left): for the timeline, which leaves samples out
- (nullable SourceSound *)soundFromFrame:(NSUInteger)frame;
@end

NS_ASSUME_NONNULL_END
