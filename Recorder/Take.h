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

// What a take writes: a movie for each source, one movie in which they are assembled, or all of them
typedef NS_ENUM(NSInteger, TakeOutput) {
    TakeOutputSeparate,
    TakeOutputAssembled,
    TakeOutputBoth
};

/*
 One movie of a take.
 */
@interface TakeMovie : NSObject
// Empty for the assembled movie
@property (readonly, copy) NSString *sourceTitle;
// Where the movie is written. If its source delivers no frame during the take, there is no file.
@property (readonly) NSURL *url;
@property (readonly) NSUInteger framesWritten;
@property (readonly) NSUInteger framesDropped;
// Why this movie stopped before the take did, nil otherwise
@property (readonly, nullable) NSError *error;
// The movie was started with a sound track. It has none in the end if no sound came.
@property (readonly) BOOL hasSound;
// Seconds of sound written, silence included
@property (readonly) NSTimeInterval soundWritten;
// Seconds of sound left out because the encoder could not take them in time
@property (readonly) NSTimeInterval soundLeftOut;
@end

/*
 The movies of one recording: one for each source, named after the take and their source, one for the picture in
 which the sources are assembled, or all of them. They share one clock, so that they line up when laid one above the
 other in an editor.

 The take does not assemble the picture: it is given it, as it is given the sources' frames.

 A take object is used for one recording after another.
 */
@interface Take : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;

// "separate", "assembled", "both"
+ (NSArray<NSString *> *)outputNames;
+ (NSString *)nameForOutput:(TakeOutput)output;
// The comparison ignores case. Returns NO, and leaves output alone, if there is no such output.
+ (BOOL)getOutput:(TakeOutput *)output forName:(NSString *)name;

// The names a take would give its sources' movies: "<name>.mov" for one source, "<name> — <title>.mov" for several.
// None of them exists: if one did, the same number is added to them all ("<name> 2 — <title>.mov").
+ (NSArray<NSURL *> *)urlsForName:(NSString *)name sourceTitles:(NSArray<NSString *> *)titles inFolder:(NSURL *)folder;

// The names of a take's movies: the sources' own (none for TakeOutputAssembled), then the assembled movie's, which is
// "<name>.mov" (nil for TakeOutputSeparate). With an assembled movie, a single source's is "<name> — <title>.mov" too.
// None exists; the same number is added to all if one did.
+ (NSArray<NSURL *> *)urlsForName:(NSString *)name
                     sourceTitles:(NSArray<NSString *> *)titles
                           output:(TakeOutput)output
                         inFolder:(NSURL *)folder
                     assembledURL:(NSURL * _Nullable * _Nullable)assembledURL;

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

// The same, with an assembled movie.
// assembledSize: the size of the assembled picture, which does not change during the take; not used for
// TakeOutputSeparate. Fails, and starts nothing, if a picture of that size cannot be written: more than 16384 on a
// side, or more than the codec can hold.
- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles
                        sizes:(NSArray *)sizes
                       output:(TakeOutput)output
                assembledSize:(NSSize)assembledSize
                         name:(NSString *)name
                       folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings
                       atTime:(NSTimeInterval)time
                        error:(NSError **)error;

// The same, with sound. The earlier ones record none.
// soundSources: the indexes of the sources whose movies have a sound track: no other has one. Indexes which are not
// sources are ignored.
// assembledSoundIndex: the source whose sound the assembled movie takes; NSNotFound for none. It need not be in
// soundSources for TakeOutputAssembled, where the sources have no movies.
// The settings' recordsSound is not used: it is set for each movie.
- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles
                        sizes:(NSArray *)sizes
                       output:(TakeOutput)output
                assembledSize:(NSSize)assembledSize
                 soundSources:(NSIndexSet *)soundSources
          assembledSoundIndex:(NSUInteger)assembledSoundIndex
                         name:(NSString *)name
                       folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings
                       atTime:(NSTimeInterval)time
                        error:(NSError **)error;

// Can be called from any thread, and returns at once. Does nothing for TakeOutputAssembled. index is the source's place in the titles given at the start.
- (void)appendTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped fromSourceAtIndex:(NSUInteger)index atTime:(NSTimeInterval)time;

// NO if the assembled picture composed for that time would not be recorded: there is no assembled movie, or its
// frame rate discards it. Asked before composing, to compose only what is written. Any thread.
- (BOOL)wantsAssembledFrameAtTime:(NSTimeInterval)time;
// The assembled picture, its first row at the top. Any thread.
- (void)appendAssembledTexture:(id<MTLTexture>)texture atTime:(NSTimeInterval)time;

// A source's sound, which arrived at time: to its own movie if it has a sound track, and to the assembled movie if it
// is the source chosen for it. Any thread; returns at once. Does nothing once the take has stopped.
- (void)appendSound:(SourceSound *)sound fromSourceAtIndex:(NSUInteger)index atTime:(NSTimeInterval)time;

// Finishes every movie. handler is called on the main queue, with an error if no movie received a frame. A movie
// which failed on its own has its error in movies.
- (void)finishAtTime:(NSTimeInterval)time completionHandler:(void (^)(NSError * _Nullable error))handler;

@property (readonly, getter=isRecording) BOOL recording;
// The sources' movies in the take being recorded, or in the last one: none for TakeOutputAssembled
@property (readonly, copy) NSArray<TakeMovie *> *movies;
// nil for TakeOutputSeparate
@property (readonly, nullable) TakeMovie *assembledMovie;
// Frames accepted which are not yet written or dropped, in all the movies
@property (readonly) NSUInteger framesPending;
// Called on the main queue when a movie fails while the take goes on. index is NSNotFound for the assembled movie.
@property (copy, nullable) void (^movieFailureHandler)(NSUInteger index, NSError *error);
@end

NS_ASSUME_NONNULL_END
