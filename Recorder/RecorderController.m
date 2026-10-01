/*
 RecorderController.m
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

#import "RecorderController.h"
#import "MovieRecorder.h"
#import "OSCReceiver.h"
#import "OSCQueryServer.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

static NSString * const kStateIdle = @"idle";
static NSString * const kStateRecording = @"recording";
static NSString * const kStateFinishing = @"finishing";

static const NSInteger kMaximumDimension = 16384;
static const double kMaximumFramesPerSecond = 240.0;
static const double kMaximumMegabitsPerSecond = 1000.0;
// How often the counters which change while recording are refreshed
static const NSTimeInterval kRefreshInterval = 0.25;

#pragma mark - Parameters

// One thing the recorder can do or tell, at an OSC address
@interface RecorderParameter : NSObject
@property (copy) NSString *address;
// OSC type tags of the arguments, nil if there are none
@property (copy) NSString *typeSpec;
@property (copy) NSString *summary;
// One dictionary for each argument, as OSCQuery's RANGE
@property (copy) NSArray<NSDictionary *> *(^range)(void);
// The current value, nil if the parameter cannot be read
@property (copy) NSArray *(^get)(void);
// Applies the arguments of a message. Returns what was wrong with them, or nil. nil if the parameter cannot be set.
@property (copy) NSString *(^set)(NSArray *arguments);
@end

@implementation RecorderParameter
@end

static NSNumber *NumberFrom(NSArray *arguments)
{
    id argument = arguments.firstObject;
    if ([argument isKindOfClass:[NSNumber class]])
    {
        return argument;
    }
    if ([argument isKindOfClass:[NSString class]])
    {
        NSScanner *scanner = [NSScanner scannerWithString:argument];
        double value;
        if ([scanner scanDouble:&value] && scanner.isAtEnd)
        {
            return @(value);
        }
    }
    return nil;
}

static NSString *StringFrom(NSArray *arguments)
{
    id argument = arguments.firstObject;
    if ([argument isKindOfClass:[NSString class]])
    {
        return argument;
    }
    return nil;
}

#pragma mark - Controller

@interface RecorderController ()
@property (readwrite, copy) NSString *state;
@property (readwrite, copy) NSString *file;
@property (readwrite, copy) NSString *error;
@property (readwrite) NSInteger oscPort;
@property (readwrite) NSInteger oscQueryPort;
@end

@implementation RecorderController {
    __weak id<RecorderSourceProvider> _provider;
    NSUserDefaults *_defaults;
    MovieRecorder *_recorder;
    NSArray<RecorderParameter *> *_parameters;
    NSDictionary<NSString *, RecorderParameter *> *_parametersByAddress;
    OSCReceiver *_receiver;
    BOOL _queryServerStarted;
    NSTimer *_refreshTimer;
    id<NSObject> _activity;
    NSTimeInterval _startTime;
    NSTimeInterval _lastElapsed;
    NSMutableArray<void (^)(void)> *_stopHandlers;

    // Guards what -frameReceived: updates
    os_unfair_lock _lock;
    NSInteger _frameWidth;
    NSInteger _frameHeight;
    NSUInteger _frameCount;
    // On the main thread: the frame rate, measured from one refresh to the next
    NSUInteger _measuredFrameCount;
    NSTimeInterval _measuredTime;
    double _sourceFPS;
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    // These are refreshed together, by -refresh
    if ([@[@"elapsed", @"frames", @"dropped", @"sourceWidth", @"sourceHeight", @"sourceFPS"] containsObject:key])
    {
        return NO;
    }
    return [super automaticallyNotifiesObserversForKey:key];
}

+ (NSSet<NSString *> *)keyPathsForValuesAffectingRecording
{
    return [NSSet setWithObject:@"state"];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                sourceProvider:(id<RecorderSourceProvider>)provider
                      defaults:(NSUserDefaults *)defaults
{
    self = [super init];
    if (self)
    {
        _provider = provider;
        _defaults = defaults;
        _lock = OS_UNFAIR_LOCK_INIT;
        _state = kStateIdle;
        _file = @"";
        _error = @"";
        _stopHandlers = [NSMutableArray array];

        NSString *movies = NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES).firstObject;
        [defaults registerDefaults:@{
            @"RecorderCodec": [MovieRecorderSettings nameForCodec:MovieCodecH264],
            @"RecorderFolder": movies ?: NSHomeDirectory(),
            @"RecorderName": @""
        }];
        MovieCodec codec;
        NSString *codecName = [defaults stringForKey:@"RecorderCodec"];
        _codec = [MovieRecorderSettings getCodec:&codec forName:codecName] ? [codecName copy] : [MovieRecorderSettings nameForCodec:MovieCodecH264];
        _width = [defaults integerForKey:@"RecorderWidth"];
        _height = [defaults integerForKey:@"RecorderHeight"];
        _fps = [defaults doubleForKey:@"RecorderFPS"];
        _bitrate = [defaults doubleForKey:@"RecorderBitrate"];
        _folder = [[defaults stringForKey:@"RecorderFolder"] copy];
        _name = [[defaults stringForKey:@"RecorderName"] copy];

        _recorder = [[MovieRecorder alloc] initWithDevice:device];
        __weak RecorderController *weakSelf = self;
        _recorder.failureHandler = ^(NSError *error) {
            [weakSelf recordingEndedWithError:error];
        };

        [self makeParameters];

        NSTimer *timer = [NSTimer timerWithTimeInterval:kRefreshInterval repeats:YES block:^(NSTimer *timer) {
            [weakSelf refresh];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        _refreshTimer = timer;
    }
    return self;
}

- (void)dealloc
{
    [_refreshTimer invalidate];
    [self stopNetwork];
}

#pragma mark Settings

- (void)setCodec:(NSString *)codec
{
    _codec = [codec copy];
    [_defaults setObject:_codec forKey:@"RecorderCodec"];
}

- (void)setWidth:(NSInteger)width
{
    _width = MIN(MAX(width, 0), kMaximumDimension);
    [_defaults setInteger:_width forKey:@"RecorderWidth"];
}

- (void)setHeight:(NSInteger)height
{
    _height = MIN(MAX(height, 0), kMaximumDimension);
    [_defaults setInteger:_height forKey:@"RecorderHeight"];
}

- (void)setFps:(double)fps
{
    _fps = isfinite(fps) ? MIN(MAX(fps, 0.0), kMaximumFramesPerSecond) : 0.0;
    [_defaults setDouble:_fps forKey:@"RecorderFPS"];
}

- (void)setBitrate:(double)bitrate
{
    _bitrate = isfinite(bitrate) ? MIN(MAX(bitrate, 0.0), kMaximumMegabitsPerSecond) : 0.0;
    [_defaults setDouble:_bitrate forKey:@"RecorderBitrate"];
}

- (void)setFolder:(NSString *)folder
{
    _folder = [(folder ?: @"").stringByExpandingTildeInPath copy];
    [_defaults setObject:_folder forKey:@"RecorderFolder"];
}

- (void)setName:(NSString *)name
{
    _name = [name ?: @"" copy];
    [_defaults setObject:_name forKey:@"RecorderName"];
}

#pragma mark State

- (BOOL)isRecording
{
    return ![self.state isEqualToString:kStateIdle];
}

- (NSTimeInterval)elapsed
{
    return [self.state isEqualToString:kStateRecording] ? CACurrentMediaTime() - _startTime : _lastElapsed;
}

- (NSUInteger)frames
{
    return _recorder.framesWritten;
}

- (NSUInteger)dropped
{
    return _recorder.framesDropped;
}

- (NSInteger)sourceWidth
{
    os_unfair_lock_lock(&_lock);
    NSInteger width = _frameWidth;
    os_unfair_lock_unlock(&_lock);
    return width;
}

- (NSInteger)sourceHeight
{
    os_unfair_lock_lock(&_lock);
    NSInteger height = _frameHeight;
    os_unfair_lock_unlock(&_lock);
    return height;
}

- (double)sourceFPS
{
    return _sourceFPS;
}

// Tells observers about the values which change by themselves
- (void)refresh
{
    NSArray<NSString *> *keys = @[@"elapsed", @"frames", @"dropped", @"sourceWidth", @"sourceHeight", @"sourceFPS"];
    for (NSString *key in keys)
    {
        [self willChangeValueForKey:key];
    }
    os_unfair_lock_lock(&_lock);
    NSUInteger frameCount = _frameCount;
    os_unfair_lock_unlock(&_lock);
    NSTimeInterval now = CACurrentMediaTime();
    if (_measuredTime > 0.0 && now > _measuredTime)
    {
        double measured = (frameCount - _measuredFrameCount) / (now - _measuredTime);
        // Smoothed, as few frames arrive between two refreshes
        _sourceFPS = (_sourceFPS == 0.0 || measured == 0.0) ? measured : 0.5 * _sourceFPS + 0.5 * measured;
    }
    _measuredFrameCount = frameCount;
    _measuredTime = now;
    for (NSString *key in keys.reverseObjectEnumerator)
    {
        [self didChangeValueForKey:key];
    }
}

#pragma mark Recording

- (BOOL)failWithError:(NSString *)error
{
    self.error = error;
    return NO;
}

- (BOOL)start
{
    if (![self.state isEqualToString:kStateIdle])
    {
        // Already recording: there is nothing to do. Finishing: the file must be finished first.
        return [self.state isEqualToString:kStateRecording] ? YES : [self failWithError:@"The previous recording is still being finished"];
    }
    self.error = @"";

    id<RecorderSourceProvider> provider = _provider;
    if ([provider selectedSourceTitle] == nil)
    {
        return [self failWithError:@"No source is selected"];
    }

    MovieRecorderSettings *settings = [[MovieRecorderSettings alloc] init];
    MovieCodec codec = MovieCodecH264;
    [MovieRecorderSettings getCodec:&codec forName:self.codec];
    settings.codec = codec;
    settings.width = self.width;
    settings.height = self.height;
    settings.framesPerSecond = self.fps;
    settings.megabitsPerSecond = self.bitrate;

    NSURL *url = [self newFileURLForSourceApplication:[provider selectedSourceApplicationName]];
    NSError *error = nil;
    if (![_recorder startWritingToURL:url settings:settings error:&error])
    {
        return [self failWithError:error.localizedDescription];
    }

    _startTime = CACurrentMediaTime();
    // Not to be slowed down or put to sleep while we record
    _activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                                                               reason:@"Recording"];
    self.file = url.path;
    self.state = kStateRecording;
    [self refresh];
    return YES;
}

// A file which does not exist yet, in the folder, called after the name chosen or the source and the date
- (NSURL *)newFileURLForSourceApplication:(NSString *)application
{
    NSString *name = self.name;
    if (name.length == 0)
    {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
        name = [NSString stringWithFormat:@"%@ %@", application.length > 0 ? application : @"Syphon", [formatter stringFromDate:[NSDate date]]];
    }
    // The name is a file's, not a path: it cannot lead out of the folder
    name = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
    if ([name hasPrefix:@"."])
    {
        name = [@"-" stringByAppendingString:[name substringFromIndex:1]];
    }

    NSURL *folder = [NSURL fileURLWithPath:self.folder isDirectory:YES];
    NSURL *url = [folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"mov"]];
    for (NSInteger copy = 2; [[NSFileManager defaultManager] fileExistsAtPath:url.path]; copy++)
    {
        NSString *numbered = [NSString stringWithFormat:@"%@ %ld", name, (long)copy];
        url = [folder URLByAppendingPathComponent:[numbered stringByAppendingPathExtension:@"mov"]];
    }
    return url;
}

- (void)stopWithCompletionHandler:(void (^)(void))handler
{
    if ([self.state isEqualToString:kStateIdle])
    {
        if (handler)
        {
            handler();
        }
        return;
    }
    if (handler)
    {
        [_stopHandlers addObject:[handler copy]];
    }
    if ([self.state isEqualToString:kStateFinishing])
    {
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    _lastElapsed = now - _startTime;
    self.state = kStateFinishing;
    __weak RecorderController *weakSelf = self;
    [_recorder finishAtTime:now completionHandler:^(NSError *error) {
        [weakSelf recordingEndedWithError:error];
    }];
}

// The file is finished, or writing failed
- (void)recordingEndedWithError:(NSError *)error
{
    if ([self.state isEqualToString:kStateIdle])
    {
        return;
    }
    if ([self.state isEqualToString:kStateRecording])
    {
        _lastElapsed = CACurrentMediaTime() - _startTime;
    }
    if (error)
    {
        self.error = error.localizedDescription;
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.file])
        {
            self.file = @"";
        }
    }
    if (_activity)
    {
        [[NSProcessInfo processInfo] endActivity:_activity];
        _activity = nil;
    }
    self.state = kStateIdle;
    [self refresh];

    NSArray<void (^)(void)> *handlers = [_stopHandlers copy];
    [_stopHandlers removeAllObjects];
    for (void (^handler)(void) in handlers)
    {
        handler();
    }
}

- (void)toggle
{
    if ([self.state isEqualToString:kStateIdle])
    {
        [self start];
    }
    else
    {
        [self stopWithCompletionHandler:nil];
    }
}

#pragma mark Sources

- (BOOL)selectSourceMatching:(NSString *)title
{
    id<RecorderSourceProvider> provider = _provider;
    if (title.length == 0)
    {
        return [self failWithError:@"/source expects the title of a source"];
    }
    NSArray<NSString *> *titles = [provider sourceTitles];
    NSUInteger index = [titles indexOfObject:title];
    if (index == NSNotFound)
    {
        index = [titles indexOfObjectPassingTest:^BOOL(NSString *candidate, NSUInteger idx, BOOL *stop) {
            return [candidate rangeOfString:title options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
    }
    if (index == NSNotFound)
    {
        return [self failWithError:[NSString stringWithFormat:@"There is no source called \u201C%@\u201D", title]];
    }
    [provider selectSourceAtIndex:index];
    return YES;
}

- (void)sourcesDidChange
{
    // The sources available are the values /source can take
    if (_queryServerStarted)
    {
        [self registerParameter:_parametersByAddress[@"/source"]];
    }
}

- (void)sourceSelectionDidChange
{
    os_unfair_lock_lock(&_lock);
    _frameWidth = 0;
    _frameHeight = 0;
    os_unfair_lock_unlock(&_lock);
    _sourceFPS = 0.0;
    [self refresh];
}

- (void)frameReceived:(id<MTLTexture>)frame
{
    os_unfair_lock_lock(&_lock);
    _frameWidth = frame.width;
    _frameHeight = frame.height;
    _frameCount++;
    os_unfair_lock_unlock(&_lock);

    // Frames from Syphon have their first row at the bottom of the picture. The recorder ignores them unless
    // it is recording.
    [_recorder appendTexture:frame flipped:YES atTime:CACurrentMediaTime()];
}

#pragma mark Parameters

- (RecorderParameter *)parameter:(NSString *)address type:(NSString *)typeSpec summary:(NSString *)summary
{
    RecorderParameter *parameter = [[RecorderParameter alloc] init];
    parameter.address = address;
    parameter.typeSpec = typeSpec;
    parameter.summary = summary;
    return parameter;
}

// A number which is read with one key and set with a block
- (RecorderParameter *)numberParameter:(NSString *)address
                                  type:(NSString *)typeSpec
                               summary:(NSString *)summary
                                   key:(NSString *)key
                               maximum:(double)maximum
{
    __weak RecorderController *weakSelf = self;
    RecorderParameter *parameter = [self parameter:address type:typeSpec summary:summary];
    parameter.range = ^{ return @[@{@"MIN": @0, @"MAX": @(maximum)}]; };
    parameter.get = ^{ return @[[weakSelf valueForKey:key] ?: @0]; };
    parameter.set = ^NSString *(NSArray *arguments) {
        NSNumber *number = NumberFrom(arguments);
        if (number == nil)
        {
            return @"expects a number";
        }
        [weakSelf setValue:number forKey:key];
        return nil;
    };
    return parameter;
}

- (RecorderParameter *)stringParameter:(NSString *)address summary:(NSString *)summary key:(NSString *)key
{
    __weak RecorderController *weakSelf = self;
    RecorderParameter *parameter = [self parameter:address type:@"s" summary:summary];
    parameter.get = ^{ return @[[weakSelf valueForKey:key] ?: @""]; };
    parameter.set = ^NSString *(NSArray *arguments) {
        NSString *string = StringFrom(arguments);
        if (string == nil)
        {
            return @"expects a string";
        }
        [weakSelf setValue:string forKey:key];
        return nil;
    };
    return parameter;
}

- (RecorderParameter *)statusParameter:(NSString *)address type:(NSString *)typeSpec summary:(NSString *)summary key:(NSString *)key
{
    __weak RecorderController *weakSelf = self;
    RecorderParameter *parameter = [self parameter:address type:typeSpec summary:summary];
    parameter.get = ^{ return @[[weakSelf valueForKey:key] ?: @0]; };
    return parameter;
}

- (void)makeParameters
{
    __weak RecorderController *weakSelf = self;

    RecorderParameter *source = [self parameter:@"/source" type:@"s"
                                        summary:@"The source to record: its title, or part of it"];
    source.range = ^{
        // Each title once: of sources with the same title, the first is selected
        NSArray<NSString *> *titles = [[NSOrderedSet orderedSetWithArray:[weakSelf sourceTitles]] array];
        return @[@{@"VALS": titles}];
    };
    source.get = ^{ return @[[weakSelf selectedSourceTitle] ?: @""]; };
    source.set = ^NSString *(NSArray *arguments) {
        NSString *title = StringFrom(arguments);
        if (title == nil)
        {
            return @"expects the title of a source";
        }
        // -selectSourceMatching: reports its own error
        [weakSelf selectSourceMatching:title];
        return nil;
    };

    RecorderParameter *record = [self parameter:@"/record" type:@"i" summary:@"1 starts recording the source, 0 stops and finishes the file"];
    record.range = ^{ return @[@{@"MIN": @0, @"MAX": @1}]; };
    record.get = ^{ return @[@([weakSelf.state isEqualToString:kStateRecording] ? 1 : 0)]; };
    record.set = ^NSString *(NSArray *arguments) {
        NSNumber *number = NumberFrom(arguments);
        if (number == nil)
        {
            return @"expects 1 to start or 0 to stop";
        }
        if (number.doubleValue != 0.0)
        {
            [weakSelf start];
        }
        else
        {
            [weakSelf stopWithCompletionHandler:nil];
        }
        return nil;
    };

    RecorderParameter *toggle = [self parameter:@"/record/toggle" type:nil summary:@"Starts recording, or stops"];
    toggle.set = ^NSString *(NSArray *arguments) {
        [weakSelf toggle];
        return nil;
    };

    RecorderParameter *codec = [self parameter:@"/codec" type:@"s" summary:@"The codec of the movie. prores4444 keeps transparency."];
    codec.range = ^{ return @[@{@"VALS": [MovieRecorderSettings codecNames]}]; };
    codec.get = ^{ return @[weakSelf.codec ?: @""]; };
    codec.set = ^NSString *(NSArray *arguments) {
        NSString *name = StringFrom(arguments).lowercaseString;
        MovieCodec value;
        if (name == nil || ![MovieRecorderSettings getCodec:&value forName:name])
        {
            return [NSString stringWithFormat:@"\u201C%@\u201D is not one of %@", arguments.firstObject ?: @"",
                    [[MovieRecorderSettings codecNames] componentsJoinedByString:@", "]];
        }
        weakSelf.codec = name;
        return nil;
    };

    _parameters = @[
        source,
        record,
        toggle,
        codec,
        [self numberParameter:@"/width" type:@"i" summary:@"Width of the movie in pixels. 0 with /height 0 for the size of the source."
                          key:@"width" maximum:kMaximumDimension],
        [self numberParameter:@"/height" type:@"i" summary:@"Height of the movie in pixels. 0 with /width 0 for the size of the source."
                          key:@"height" maximum:kMaximumDimension],
        [self numberParameter:@"/fps" type:@"f" summary:@"The most frames the movie has each second. 0 keeps every frame of the source."
                          key:@"fps" maximum:kMaximumFramesPerSecond],
        [self numberParameter:@"/bitrate" type:@"f" summary:@"Megabits per second for h264 and hevc. 0 chooses from the size and frame rate."
                          key:@"bitrate" maximum:kMaximumMegabitsPerSecond],
        [self stringParameter:@"/folder" summary:@"The folder movies are written to" key:@"folder"],
        [self stringParameter:@"/name" summary:@"The name of the movie, without extension. Empty for the source's application and the date."
                          key:@"name"],
        [self statusParameter:@"/status/state" type:@"s" summary:@"idle, recording, or finishing while the file is completed" key:@"state"],
        [self statusParameter:@"/status/elapsed" type:@"f" summary:@"Seconds recorded" key:@"elapsed"],
        [self statusParameter:@"/status/frames" type:@"i" summary:@"Frames written to the movie" key:@"frames"],
        [self statusParameter:@"/status/dropped" type:@"i" summary:@"Frames lost because the encoder could not keep up" key:@"dropped"],
        [self statusParameter:@"/status/file" type:@"s" summary:@"The movie being written, or the last one written" key:@"file"],
        [self statusParameter:@"/status/error" type:@"s" summary:@"The last error. Empty when a recording starts." key:@"error"],
        [self statusParameter:@"/status/source/width" type:@"i" summary:@"Width of the source's frames" key:@"sourceWidth"],
        [self statusParameter:@"/status/source/height" type:@"i" summary:@"Height of the source's frames" key:@"sourceHeight"],
        [self statusParameter:@"/status/source/fps" type:@"f" summary:@"Frames the source delivers each second" key:@"sourceFPS"]
    ];

    NSMutableDictionary *byAddress = [NSMutableDictionary dictionary];
    for (RecorderParameter *parameter in _parameters)
    {
        byAddress[parameter.address] = parameter;
    }
    _parametersByAddress = byAddress;
}

- (NSArray<NSString *> *)sourceTitles
{
    return [_provider sourceTitles] ?: @[];
}

- (NSString *)selectedSourceTitle
{
    return [_provider selectedSourceTitle];
}

- (void)handleMessage:(OSCMessage *)message
{
    RecorderParameter *parameter = _parametersByAddress[message.address];
    if (parameter.set == nil)
    {
        // Not ours, or only to be read
        return;
    }
    NSString *problem = parameter.set(message.arguments);
    if (problem)
    {
        self.error = [NSString stringWithFormat:@"%@ %@", message.address, problem];
    }
}

#pragma mark Network

- (void)registerParameter:(RecorderParameter *)parameter
{
    OSCQueryAccess access = parameter.get ? (parameter.set ? OSCQueryAccessReadWrite : OSCQueryAccessReadOnly) : OSCQueryAccessWriteOnly;
    [[OSCQueryServer sharedServer] registerOSCAddress:parameter.address
                                             typeSpec:parameter.typeSpec
                                          description:parameter.summary
                                               access:access
                                                range:parameter.range ? parameter.range() : nil
                                        valueProvider:parameter.get];
}

- (BOOL)startNetworkWithOSCPort:(NSInteger)oscPort queryPort:(NSInteger)queryPort name:(NSString *)name
{
    [self stopNetwork];

    __weak RecorderController *weakSelf = self;
    OSCReceiver *receiver = [[OSCReceiver alloc] init];
    if (![receiver startOnPort:oscPort handler:^(OSCMessage *message) {
        [weakSelf handleMessage:message];
    }])
    {
        return [self failWithError:[NSString stringWithFormat:@"OSC could not listen on UDP port %ld or those which follow", (long)oscPort]];
    }
    _receiver = receiver;
    self.oscPort = receiver.port;

    OSCQueryServer *server = [OSCQueryServer sharedServer];
    server.serverName = name;
    server.oscPort = receiver.port;
    [server clearRegisteredAddresses];
    for (RecorderParameter *parameter in _parameters)
    {
        [self registerParameter:parameter];
    }
    if (![server startOnPort:queryPort])
    {
        return [self failWithError:[NSString stringWithFormat:@"OSCQuery could not listen on TCP port %ld or those which follow", (long)queryPort]];
    }
    _queryServerStarted = YES;
    self.oscQueryPort = server.httpPort;
    return YES;
}

- (void)stopNetwork
{
    [_receiver stop];
    _receiver = nil;
    if (_queryServerStarted)
    {
        [[OSCQueryServer sharedServer] stop];
        [[OSCQueryServer sharedServer] clearRegisteredAddresses];
        _queryServerStarted = NO;
    }
    if (_oscPort != 0)
    {
        self.oscPort = 0;
    }
    if (_oscQueryPort != 0)
    {
        self.oscQueryPort = 0;
    }
}

@end
