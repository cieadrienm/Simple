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
#import "OSCMessage.h"

NS_ASSUME_NONNULL_BEGIN

/*
 What the recorder needs to know about the sources which can be recorded. Used on the main thread.
 */
@protocol RecorderSourceProvider <NSObject>
// The sources available, as they are shown to the user
- (NSArray<NSString *> *)sourceTitles;
- (nullable NSString *)selectedSourceTitle;
- (nullable NSString *)selectedSourceApplicationName;
// index is into sourceTitles
- (void)selectSourceAtIndex:(NSInteger)index;
@end

/*
 Records the frames of the selected source to movie files.

 Everything the recorder can do is a parameter with an OSC address: the properties below are those parameters, the
 window binds to them, OSC messages set them, and OSCQuery describes and reads them. See -startNetworkWithOSCPort:...

 Use on the main thread, except for -frameReceived:
 */
@interface RecorderController : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device
                sourceProvider:(id<RecorderSourceProvider>)provider
                      defaults:(NSUserDefaults *)defaults;

// Settings. They are saved in the defaults, and a change applies to the next recording.
@property (nonatomic, copy) NSString *codec;      // /codec: one of +[MovieRecorderSettings codecNames]
@property (nonatomic, assign) NSInteger width;    // /width, /height: 0 for the size of the source
@property (nonatomic, assign) NSInteger height;
@property (nonatomic, assign) double fps;         // /fps: 0 for every frame of the source
@property (nonatomic, assign) double bitrate;     // /bitrate: megabits per second, 0 for automatic
@property (nonatomic, copy) NSString *folder;     // /folder
@property (nonatomic, copy) NSString *name;       // /name: empty for the source's application and the date

// State
@property (readonly, copy) NSString *state;       // /status/state: "idle", "recording" or "finishing"
@property (readonly, getter=isRecording) BOOL recording;
@property (readonly) NSTimeInterval elapsed;      // /status/elapsed
@property (readonly) NSUInteger frames;           // /status/frames
@property (readonly) NSUInteger dropped;          // /status/dropped
@property (readonly, copy) NSString *file;        // /status/file: being written, or the last one written
@property (readonly, copy) NSString *error;       // /status/error: the last error, empty when a recording starts
@property (readonly) NSInteger sourceWidth;       // /status/source/width, height, fps
@property (readonly) NSInteger sourceHeight;
@property (readonly) double sourceFPS;

// Starts recording the selected source. Returns NO, with the reason in error, if it could not.
- (BOOL)start;
// handler is called once the file is finished, or at once if there is no recording
- (void)stopWithCompletionHandler:(nullable void (^)(void))handler;
- (void)toggle;

// Selects the source with this title or, failing that, the first whose title contains it, whatever the case.
// Returns NO, with the reason in error, if there is no such source.
- (BOOL)selectSourceMatching:(NSString *)title;
// Tell the recorder when the sources available change, and when another is selected
- (void)sourcesDidChange;
- (void)sourceSelectionDidChange;
// Give the recorder every frame of the selected source. Can be called from any thread.
- (void)frameReceived:(id<MTLTexture>)frame;

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
