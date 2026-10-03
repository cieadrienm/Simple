/*
 RecorderController.h
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
#import "FrameSource.h"
#import "Layout.h"
#import "OSCMessage.h"

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread whenever something the recorder shows has changed, and four times a second for what
// changes by itself (the time recorded, frame counts, frame rates). The object is the controller.
extern NSNotificationName const RecorderControllerDidChangeNotification;

// The most sources which can be recorded at once
extern const NSUInteger RecorderMaximumPlaces;

/*
 One of the sources chosen for recording, and what it is doing. Places are numbered from 1, in the order chosen.
 */
@interface RecorderPlace : NSObject
@property (readonly, copy) NSString *title;
// YES if the source is delivering frames. A source which has gone keeps its place, and takes it again when it is back.
@property (readonly, getter=isOnline) BOOL online;
@property (readonly) NSInteger width;
@property (readonly) NSInteger height;
@property (readonly) double fps;
// Its movie in the take being recorded, or in the last one. Empty if it has none.
@property (readonly, copy) NSString *file;
@property (readonly) NSUInteger frames;
@property (readonly) NSUInteger dropped;
// The last frame it delivered, to show it
@property (readonly, nullable) id<MTLTexture> latestFrame;
// YES if the first row of latestFrame is the bottom of the picture
@property (readonly) BOOL flipped;
@end

/*
 Records the sources chosen: each to its own movie, all in one movie in which they are assembled, or both.

 Everything the recorder can do is a parameter with an OSC address: the properties below are those parameters, the
 window shows them, OSC messages set them, and OSCQuery describes and reads them. See -startNetworkWithOSCPort:...

 Use on the main thread.
 */
@interface RecorderController : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device
                     directory:(id<SourceDirectory>)directory
                      defaults:(NSUserDefaults *)defaults;

// The device the sources' frames are textures of
@property (readonly) id<MTLDevice> device;

// Settings. They are saved in the defaults, and a change applies to the next recording.
@property (nonatomic, copy) NSString *codec;      // /codec: one of +[MovieRecorderSettings codecNames]
@property (nonatomic, assign) NSInteger width;    // /width, /height: the size the assembled picture is fitted into, 0 for
@property (nonatomic, assign) NSInteger height;   //   automatic; a source's own movie is always the size of the source
@property (nonatomic, assign) double fps;         // /fps: 0 for every frame of the source
@property (nonatomic, assign) double bitrate;     // /bitrate: megabits per second, 0 for automatic
@property (nonatomic, copy) NSString *folder;     // /folder
@property (nonatomic, copy) NSString *name;       // /name: empty for the app's name and the date
// What a take writes, and how the sources are assembled. A name which does not exist changes nothing.
@property (nonatomic, copy) NSString *output;     // /output: one of +[Take outputNames]: "separate", "assembled", "both"
@property (nonatomic, copy) NSString *layout;     // /layout: one of +[Layout kindNames]: "row", "column", "grid", "focus"
@property (nonatomic, assign) NSInteger gap;      // /gap: pixels between sources in the assembled picture

// The sources chosen, in order: /source/1 … /source/8 (and /source, which is /source/1). They are saved in the
// defaults. Only these are connected to. They cannot be changed while recording.
@property (readonly, copy) NSArray<RecorderPlace *> *places;
// The sources which can be chosen
@property (readonly, copy) NSArray<SourceDescription *> *availableSources;
// Chooses the source with this title or, failing that, the first whose title contains it, whatever the case, and
// gives it the next place. YES if it is chosen (it may have been already).
- (BOOL)addSourceMatching:(NSString *)title;
// Gives a place (from 1) to a source: the source which had the place leaves it; a source chosen already moves
// there; a place beyond the last is the next one. An empty title empties the place, and those after it move up.
- (BOOL)setSourceMatching:(NSString *)title atPlace:(NSUInteger)place;
- (void)removeSourceAtPlace:(NSUInteger)place;
- (BOOL)moveSourceFromPlace:(NSUInteger)from toPlace:(NSUInteger)to;
// These return NO, with the reason in error, if there is no such source or place, if every place is taken, or
// while recording.

// State
@property (readonly, copy) NSString *state;       // /status/state: "idle", "recording" or "finishing"
@property (readonly, getter=isRecording) BOOL recording;
@property (readonly) NSTimeInterval elapsed;      // /status/elapsed
// /status/frames and /status/file: of the assembled movie if the take (being recorded, or the last) has one, of the
// first place's movie otherwise
@property (readonly) NSUInteger frames;
@property (readonly) NSUInteger dropped;          // /status/dropped: frames dropped in all the movies
@property (readonly, copy) NSString *file;

// The assembled picture: that of the take while one is recorded to an assembled movie (it does not change during
// the take), otherwise that of the settings and of the sources as they are.
@property (readonly) Layout *assembledLayout;                   // /status/assembled/width, /height: its size
// The last picture composed, to show it: its first row is the top. It may be smaller than the picture recorded (no
// more than 4096 on a side when it is composed only to be shown). nil if there is no source.
@property (readonly, nullable) id<MTLTexture> assembledFrame;
// The assembled movie of the take being recorded, or of the last one
@property (readonly, copy) NSString *assembledFile;             // /status/assembled/file: empty if there is none
@property (readonly) NSUInteger assembledFrames;                // /status/assembled/frames
@property (readonly) NSUInteger assembledDropped;               // /status/assembled/dropped
@property (nonatomic, readonly, copy) NSString *error; // /status/error: the last error, empty when a recording starts
// How many errors there have been: it changes when an error happens again, which error alone does not show
@property (readonly) NSUInteger errorCount;
// /status/failure: why the last recording ended, if it was not as asked: it failed, or had nothing to write. Empty
// otherwise, and when a recording starts. Unlike error, a message which was refused meanwhile does not change it.
@property (readonly, copy) NSString *recordingError;

// Starts recording the sources chosen. Returns NO, with the reason in error, if it could not.
- (BOOL)start;
// handler is called once the movies are finished, or at once if there is no recording
- (void)stopWithCompletionHandler:(nullable void (^)(void))handler;
- (void)toggle;

// Listens for OSC messages on a UDP port, and describes the parameters to OSCQuery clients over HTTP, announced by
// Bonjour under name. Each port is the first which is free from the one given. Returns NO if either could not start.
- (BOOL)startNetworkWithOSCPort:(NSInteger)oscPort queryPort:(NSInteger)queryPort name:(NSString *)name;
- (void)stopNetwork;
// The ports in use, 0 when the network is stopped
@property (readonly) NSInteger oscPort;
@property (readonly) NSInteger oscQueryPort;
// What an OSC message does. Problems are reported in error.
- (void)handleMessage:(OSCMessage *)message;
@end

NS_ASSUME_NONNULL_END
