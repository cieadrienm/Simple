/*
 SoundTimeline.m
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

#import "SoundTimeline.h"
#import "SourceSound.h"

// How far the stream's end may be from the clock before it is corrected, in seconds
static const double Tolerance = 0.1;
// The longest piece of silence given at once, in seconds
static const double LongestSilence = 10.0;

/*
 The stream is a series of runs, one for each sample rate it has had in turn. Within a run everything is counted in
 whole samples, so that a piece follows the last one exactly; only a run's start is in seconds.
 */
@implementation SoundTimeline {
    NSTimeInterval _origin;
    // Of the current run: 0 before the first piece
    double _rate;
    NSTimeInterval _runStart;
    long long _written;
    long long _silence;
    long long _leftOut;
    // Of the runs before it
    NSTimeInterval _silenceBefore;
    NSTimeInterval _leftOutBefore;
}

- (instancetype)initWithOrigin:(NSTimeInterval)origin
{
    self = [super init];
    if (self)
    {
        _origin = origin;
    }
    return self;
}

- (NSTimeInterval)writtenDuration
{
    return _rate > 0.0 ? _runStart + _written / _rate : _runStart;
}

- (NSTimeInterval)silenceAdded
{
    return _rate > 0.0 ? _silenceBefore + _silence / _rate : _silenceBefore;
}

- (NSTimeInterval)soundLeftOut
{
    return _rate > 0.0 ? _leftOutBefore + _leftOut / _rate : _leftOutBefore;
}

- (void)startRunAtRate:(double)rate
{
    _runStart = self.writtenDuration;
    _silenceBefore = self.silenceAdded;
    _leftOutBefore = self.soundLeftOut;
    _written = 0;
    _silence = 0;
    _leftOut = 0;
    _rate = rate;
}

- (NSArray<SourceSound *> *)piecesForSound:(SourceSound *)sound arrivedAtTime:(NSTimeInterval)time
{
    if (sound.sampleRate != _rate)
    {
        [self startRunAtRate:sound.sampleRate];
    }

    long long frameCount = (long long)sound.frameCount;
    // Where the piece belongs, in samples of this run, and how far that is from the stream's end
    NSTimeInterval place = time - sound.duration - _origin;
    long long error = llround((place - _runStart) * _rate) - _written;
    long long tolerance = llround(Tolerance * _rate);

    if (error > tolerance)
    {
        // Late: silence fills the hole
        NSMutableArray<SourceSound *> *pieces = [NSMutableArray array];
        long long longest = llround(LongestSilence * _rate);
        for (long long left = error; left > 0; left -= longest)
        {
            [pieces addObject:[SourceSound silenceOfFrameCount:(NSUInteger)MIN(left, longest) sampleRate:_rate]];
        }
        [pieces addObject:sound];
        _silence += error;
        _written += error + frameCount;
        return pieces;
    }
    if (error < -tolerance)
    {
        // Early: what overlaps the stream is left out
        long long overlap = -error;
        if (overlap >= frameCount)
        {
            _leftOut += frameCount;
            return @[];
        }
        _leftOut += overlap;
        _written += frameCount - overlap;
        return @[[sound soundFromFrame:(NSUInteger)overlap]];
    }
    _written += frameCount;
    return @[sound];
}

@end
