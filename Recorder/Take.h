/*
 Take.h
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
#import "MovieRecorder.h"

NS_ASSUME_NONNULL_BEGIN

/*
 One movie of a take.
 */
@interface TakeMovie : NSObject
@property (readonly, copy) NSString *sourceTitle;
// Where the movie is written. If its source delivers no frame during the take, there is no file.
@property (readonly) NSURL *url;
@property (readonly) NSUInteger framesWritten;
@property (readonly) NSUInteger framesDropped;
// Why this movie stopped before the take did, nil otherwise
@property (readonly, nullable) NSError *error;
@end

/*
 The movies of one recording: one for each source, named after the take and their source, sharing one clock so that
 they line up when laid one above the other in an editor.

 A take object is used for one recording after another.
 */
@interface Take : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;

// The names a take would give its movies: "<name>.mov" for one source, "<name> — <title>.mov" for several.
// None of them exists: if one did, the same number is added to them all ("<name> 2 — <title>.mov").
+ (NSArray<NSURL *> *)urlsForName:(NSString *)name sourceTitles:(NSArray<NSString *> *)titles inFolder:(NSURL *)folder;

// sizes: for each source, the size of its frames if it is known (an NSValue of an NSSize), NSNull if not. A movie
// is the size of its source: the settings' width and height are not used.
// time: the take's time zero, on the clock of appendTexture:… and finishAtTime:…
// Fails if a take is being recorded or finished, if there is no source, or if the folder cannot be written to.
- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles
                        sizes:(NSArray *)sizes
                         name:(NSString *)name
                       folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings
                       atTime:(NSTimeInterval)time
                        error:(NSError **)error;

// Can be called from any thread, and returns at once. index is the source's place in the titles given at the start.
- (void)appendTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped fromSourceAtIndex:(NSUInteger)index atTime:(NSTimeInterval)time;

// Finishes every movie. handler is called on the main queue, with an error if no movie received a frame. A movie
// which failed on its own has its error in movies.
- (void)finishAtTime:(NSTimeInterval)time completionHandler:(void (^)(NSError * _Nullable error))handler;

@property (readonly, getter=isRecording) BOOL recording;
// The movies of the take being recorded, or of the last one
@property (readonly, copy) NSArray<TakeMovie *> *movies;
// Frames accepted which are not yet written or dropped, in all the movies
@property (readonly) NSUInteger framesPending;
// Called on the main queue when a movie fails while the take goes on
@property (copy, nullable) void (^movieFailureHandler)(NSUInteger index, NSError *error);
@end

NS_ASSUME_NONNULL_END
