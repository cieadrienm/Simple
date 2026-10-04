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

/*
 A single piece's arrival jitters by tens of milliseconds, so a piece is never corrected on its own evidence unless it
 is far out (the hard tolerance: sound was away, or was left out). The average of the error over a couple of seconds
 of sound is steady: it is what keeps the sound within about a frame of the pictures, at the start and over hours,
 by a correction whenever it passes the soft tolerance.
 */
// Beyond it, a piece is placed exactly where it belongs, in seconds
static const double HardTolerance = 0.1;
// Beyond it, the smoothed error is corrected, in seconds
static const double SoftTolerance = 0.02;
// The time constant of the smoothed error, in seconds of sound
static const double TimeConstant = 2.0;
// The longest piece of silence given at once, in seconds
static const double LongestSilence = 10.0;
// The farthest from the stream's end a piece may be placed, in seconds: beyond it the time given is taken as wrong
static const double Reach = 24 * 3600.0;

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
    // Whether its first piece has been placed, and the smoothed error since the last correction, in samples
    BOOL _anchored;
    double _smoothedError;
    // Of the runs before it
    NSTimeInterval _silenceBefore;
    NSTimeInterval _leftOutBefore;
    // The longest piece of silence at the run's rate, given again for every long one
    SourceSound *_longestSilence;
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
    _anchored = NO;
    _smoothedError = 0.0;
    _longestSilence = nil;
}

- (NSArray<SourceSound *> *)piecesForSound:(SourceSound *)sound arrivedAtTime:(NSTimeInterval)time
{
    // Where the piece belongs, in seconds from the origin
    NSTimeInterval place = time - sound.duration - _origin;
    if (!isfinite(place) || fabs(place - self.writtenDuration) > Reach)
    {
        return @[];
    }
    if (sound.sampleRate != _rate)
    {
        [self startRunAtRate:sound.sampleRate];
    }

    long long frameCount = (long long)sound.frameCount;
    // How far the piece's place is from the stream's end, in samples of this run
    long long error = llround((place - _runStart) * _rate) - _written;

    // The correction to make: the error itself, or its smoothed value once it is steady
    long long correction = 0;
    BOOL wasAnchored = _anchored;
    if (!_anchored || llabs(error) > llround(HardTolerance * _rate))
    {
        _anchored = YES;
        correction = error;
        _smoothedError = 0.0;
    }
    else
    {
        _smoothedError += MIN(1.0, sound.duration / TimeConstant) * (error - _smoothedError);
        if (fabs(_smoothedError) > SoftTolerance * _rate)
        {
            correction = llround(_smoothedError);
            _smoothedError = 0.0;
        }
    }

    if (correction > 0)
    {
        // Late: silence fills the hole, the longest pieces all one and the same
        NSMutableArray<SourceSound *> *pieces = [NSMutableArray array];
        long long longest = llround(LongestSilence * _rate);
        long long left = correction;
        for (; left >= longest; left -= longest)
        {
            if (_longestSilence == nil)
            {
                _longestSilence = [SourceSound silenceOfFrameCount:(NSUInteger)longest sampleRate:_rate];
            }
            [pieces addObject:_longestSilence];
        }
        if (left > 0)
        {
            [pieces addObject:[SourceSound silenceOfFrameCount:(NSUInteger)left sampleRate:_rate]];
        }
        [pieces addObject:sound];
        _silence += correction;
        _written += correction + frameCount;
        return pieces;
    }
    if (correction < 0)
    {
        // Early: what overlaps the stream is left out
        long long overlap = -correction;
        if (overlap >= frameCount)
        {
            // Nothing of it is written: the run is anchored by the first piece which is
            _anchored = wasAnchored;
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
