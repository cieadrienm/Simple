/*
 ComputerSound.h
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
#import <CoreAudio/CoreAudio.h>

@class SourceSound;

NS_ASSUME_NONNULL_BEGIN

/*
 Something which delivers the sound being played on this Mac while a take records it. Used on the main thread.
 */
@protocol SoundSource <NSObject>
// Called for every piece of sound while it is running, on any thread
@property (copy, nullable) void (^soundHandler)(SourceSound *sound);
// Starts delivering sound. Returns NO if it could not.
- (BOOL)start;
- (void)stop;
@end

/*
 Captures the sound being played by all applications on this Mac, through a Core Audio process tap.
 */
@interface ComputerSound : NSObject <SoundSource>
// Makes a piece of sound from a Core Audio input buffer list of 32-bit float samples (interleaved or planar,
// one or more channels). nil if the format is not 32-bit float, if there are no samples, or if ignoreIfSilent
// is YES when every sample kept is zero.
+ (nullable SourceSound *)soundFromBufferList:(const AudioBufferList *_Nullable)bufferList
                                       format:(AudioStreamBasicDescription)format
                               ignoreIfSilent:(BOOL)ignoreIfSilent;
@end

NS_ASSUME_NONNULL_END
