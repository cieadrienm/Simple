/*
 FramePacer.h
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

typedef struct {
    BOOL keep;
    // Presentation time in seconds, 0 for the first frame
    double time;
} FramePacerDecision;

/*
 Decides which of the frames arriving from a source are kept for a recording with a maximum frame rate, and when each
 is shown in the movie.

 With a maximum, time is divided into slots of one frame and the first frame to arrive for each slot is kept. Slots are
 centred on their time, so a source running at the maximum rate keeps all of its frames even when they arrive unevenly.
 */
@interface FramePacer : NSObject
// framesPerSecond 0 keeps every frame, at the time it arrived
- (instancetype)initWithFramesPerSecond:(double)framesPerSecond;
// time: when the frame arrived, in seconds from any origin. The first call defines time 0.
- (FramePacerDecision)decisionForFrameAtTime:(double)time;
@end

NS_ASSUME_NONNULL_END
