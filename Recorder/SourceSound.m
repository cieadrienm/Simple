/*
 SourceSound.m
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

#import "SourceSound.h"

static BOOL IsUsableRate(double sampleRate)
{
    return isfinite(sampleRate) && sampleRate > 0.0;
}

// Whether frameCount stereo frames fit in a buffer whose size in bytes is a NSUInteger
static BOOL IsUsableFrameCount(NSUInteger frameCount)
{
    return frameCount > 0 && frameCount <= NSUIntegerMax / (2 * sizeof(float));
}

@implementation SourceSound {
    float *_buffer;
}

// Takes ownership of buffer, which holds frameCount × 2 floats (and is not NULL, even for no frame)
- (instancetype)initWithBuffer:(float *)buffer frameCount:(NSUInteger)frameCount sampleRate:(double)sampleRate
{
    self = [super init];
    if (self)
    {
        _buffer = buffer;
        _frameCount = frameCount;
        _sampleRate = sampleRate;
    }
    return self;
}

- (void)dealloc
{
    free(_buffer);
}

+ (instancetype)soundWithPlanarSamples:(const float *)samples
                          channelCount:(NSUInteger)channelCount
                            frameCount:(NSUInteger)frameCount
                  channelStrideInBytes:(NSUInteger)stride
                            sampleRate:(double)sampleRate
{
    if (samples == NULL || channelCount == 0 || !IsUsableFrameCount(frameCount) || !IsUsableRate(sampleRate))
    {
        return nil;
    }
    // The second plane is read only when there are several
    if (channelCount > 1 && (stride < frameCount * sizeof(float) || stride % sizeof(float) != 0))
    {
        return nil;
    }
    float *buffer = malloc(frameCount * 2 * sizeof(float));
    if (buffer == NULL)
    {
        return nil;
    }
    const float *left = samples;
    const float *right = channelCount > 1 ? samples + stride / sizeof(float) : samples;
    for (NSUInteger frame = 0; frame < frameCount; frame++)
    {
        buffer[frame * 2] = left[frame];
        buffer[frame * 2 + 1] = right[frame];
    }
    return [[self alloc] initWithBuffer:buffer frameCount:frameCount sampleRate:sampleRate];
}

+ (instancetype)soundWithInterleavedStereoSamples:(const float *)samples
                                       frameCount:(NSUInteger)frameCount
                                       sampleRate:(double)sampleRate
{
    if (samples == NULL || !IsUsableFrameCount(frameCount) || !IsUsableRate(sampleRate))
    {
        return nil;
    }
    float *buffer = malloc(frameCount * 2 * sizeof(float));
    if (buffer == NULL)
    {
        return nil;
    }
    memcpy(buffer, samples, frameCount * 2 * sizeof(float));
    return [[self alloc] initWithBuffer:buffer frameCount:frameCount sampleRate:sampleRate];
}

+ (instancetype)silenceOfFrameCount:(NSUInteger)frameCount sampleRate:(double)sampleRate
{
    NSParameterAssert(IsUsableRate(sampleRate));
    NSParameterAssert(frameCount <= NSUIntegerMax / (2 * sizeof(float)));
    // At least one frame's worth, so that samples is never NULL
    float *buffer = calloc(MAX(frameCount, 1) * 2, sizeof(float));
    if (buffer == NULL)
    {
        [NSException raise:NSMallocException format:@"No memory for %lu frames of silence", (unsigned long)frameCount];
    }
    return [[self alloc] initWithBuffer:buffer frameCount:frameCount sampleRate:sampleRate];
}

- (const float *)samples
{
    return _buffer;
}

- (NSTimeInterval)duration
{
    return _frameCount / _sampleRate;
}

- (SourceSound *)soundFromFrame:(NSUInteger)frame
{
    if (frame >= _frameCount)
    {
        return nil;
    }
    if (frame == 0)
    {
        return self;
    }
    return [SourceSound soundWithInterleavedStereoSamples:_buffer + frame * 2
                                               frameCount:_frameCount - frame
                                               sampleRate:_sampleRate];
}

@end
