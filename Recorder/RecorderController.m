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
#import "Take.h"
#import "Compositor.h"
#import "OSCReceiver.h"
#import "OSCQueryServer.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

NSNotificationName const RecorderControllerDidChangeNotification = @"RecorderControllerDidChangeNotification";
const NSUInteger RecorderMaximumPlaces = 8;

static NSString * const kStateIdle = @"idle";
static NSString * const kStateRecording = @"recording";
static NSString * const kStateFinishing = @"finishing";
// What the assembled movie is called in an error, where a source's movie has its source's title
static NSString * const kAssembledMovieTitle = @"Assembled movie";

static const NSInteger kMaximumDimension = 16384;
static const double kMaximumFramesPerSecond = 240.0;
static const double kMaximumMegabitsPerSecond = 1000.0;
static const NSInteger kMaximumGap = 1000;
// When no take needs it, the assembled picture is composed this often at most, to be shown
static const NSTimeInterval kMonitorInterval = 1.0 / 30.0;
// and no larger than this on a side: it is to be looked at in a window, whatever the size it is recorded at
static const CGFloat kMonitorLargestSide = 4096.0;
// How often what changes by itself is refreshed
static const NSTimeInterval kRefreshInterval = 0.25;
// A source which has delivered no frame for this long is not online
static const NSTimeInterval kOnlineTimeout = 1.0;
// A source which has delivered no frame for this long is asked whether it is alive, and a place without its
// source tries for it again this often
static const NSTimeInterval kSilenceTimeout = 2.0;
// Asking a source whether it is alive makes a client in its application: one which stays silent (a picture which
// does not move) is asked after twice as long each time, up to this
static const NSTimeInterval kLongestSilenceTimeout = 30.0;

#pragma mark - SourceDescription

@implementation SourceDescription

- (instancetype)initWithTitle:(NSString *)title detail:(NSString *)detail kind:(FrameSourceKind)kind
{
    self = [super init];
    if (self)
    {
        _title = [title copy];
        _detail = [detail copy];
        _kind = kind;
    }
    return self;
}

@end

#pragma mark - RecorderPlace

@interface RecorderPlace ()
@property (readwrite, copy) NSString *title;
// Main thread: the connection to the source, nil while it is away
@property (strong, nullable) id<FrameSource> source;
// Main thread: the place's movie in the current or last take
@property (strong, nullable) TakeMovie *movie;
@property (assign) BOOL inTake;
// Main thread: when the place last connected, tried to, or asked its source whether it is alive
@property (assign) NSTimeInterval checkTime;
// Main thread: how many times in a row its source was found alive and silent
@property (assign) NSUInteger silentChecks;
@property (readwrite) FrameSourceKind kind;
// Main thread: YES once it has connected, and its kind is known
@property (assign) BOOL kindKnown;
- (void)letGoOfSource;
@end

@implementation RecorderPlace {
    // Guards what a frame changes
    os_unfair_lock _lock;
    id<MTLTexture> _latestFrame;
    BOOL _flipped;
    NSInteger _width;
    NSInteger _height;
    NSUInteger _frameCount;
    NSTimeInterval _lastFrameTime;
    // The source's index in the take being recorded, NSNotFound otherwise
    NSUInteger _takeIndex;
    // Main thread: the frame rate, measured from one refresh to the next
    NSUInteger _measuredFrameCount;
    NSTimeInterval _measuredTime;
    double _fps;
    BOOL _online;
}

- (instancetype)initWithTitle:(NSString *)title
{
    self = [super init];
    if (self)
    {
        _title = [title copy];
        _lock = OS_UNFAIR_LOCK_INIT;
        _takeIndex = NSNotFound;
    }
    return self;
}

// Any thread. Returns the source's index in the take, NSNotFound if it is not being recorded.
- (NSUInteger)receivedFrame:(id<MTLTexture>)frame flipped:(BOOL)flipped atTime:(NSTimeInterval)time
{
    os_unfair_lock_lock(&_lock);
    _latestFrame = frame;
    _flipped = flipped;
    _width = frame.width;
    _height = frame.height;
    _frameCount++;
    _lastFrameTime = time;
    NSUInteger index = _takeIndex;
    os_unfair_lock_unlock(&_lock);
    return index;
}

// Main thread: stops its source, then forgets its last frame, which is not drawn again: its part of the picture is
// empty until a frame arrives from a new connection. Its size stays, so that the layout does not jump. In this
// order, as a source delivers nothing once stop has returned.
- (void)letGoOfSource
{
    [self.source stop];
    self.source = nil;
    os_unfair_lock_lock(&_lock);
    _latestFrame = nil;
    os_unfair_lock_unlock(&_lock);
}

- (void)setTakeIndex:(NSUInteger)index
{
    os_unfair_lock_lock(&_lock);
    _takeIndex = index;
    os_unfair_lock_unlock(&_lock);
}

// Main thread, at each refresh
- (void)measureAtTime:(NSTimeInterval)now
{
    os_unfair_lock_lock(&_lock);
    NSUInteger frameCount = _frameCount;
    NSTimeInterval lastFrameTime = _lastFrameTime;
    os_unfair_lock_unlock(&_lock);

    _online = self.source != nil && lastFrameTime > 0.0 && now - lastFrameTime < kOnlineTimeout;
    if (_measuredTime > 0.0 && now > _measuredTime)
    {
        double measured = (frameCount - _measuredFrameCount) / (now - _measuredTime);
        // Smoothed, as few frames arrive between two refreshes
        _fps = (_fps == 0.0 || measured == 0.0) ? measured : 0.5 * _fps + 0.5 * measured;
    }
    _measuredFrameCount = frameCount;
    _measuredTime = now;
}

- (BOOL)isOnline
{
    return _online;
}

// When the last frame arrived, 0 if none has
- (NSTimeInterval)lastFrameTime
{
    os_unfair_lock_lock(&_lock);
    NSTimeInterval time = _lastFrameTime;
    os_unfair_lock_unlock(&_lock);
    return time;
}

- (double)fps
{
    return _fps;
}

- (NSInteger)width
{
    os_unfair_lock_lock(&_lock);
    NSInteger width = _width;
    os_unfair_lock_unlock(&_lock);
    return width;
}

- (NSInteger)height
{
    os_unfair_lock_lock(&_lock);
    NSInteger height = _height;
    os_unfair_lock_unlock(&_lock);
    return height;
}

- (id<MTLTexture>)latestFrame
{
    os_unfair_lock_lock(&_lock);
    id<MTLTexture> frame = _latestFrame;
    os_unfair_lock_unlock(&_lock);
    return frame;
}

- (BOOL)flipped
{
    os_unfair_lock_lock(&_lock);
    BOOL flipped = _flipped;
    os_unfair_lock_unlock(&_lock);
    return flipped;
}

- (NSString *)file
{
    // A movie which received no frame has no file
    TakeMovie *movie = self.movie;
    return (movie && (self.inTake || movie.framesWritten > 0)) ? movie.url.path : @"";
}

- (NSUInteger)frames
{
    return self.movie.framesWritten;
}

- (NSUInteger)dropped
{
    return self.movie.framesDropped;
}

- (NSString *)kindName
{
    if (!self.kindKnown)
    {
        return @"";
    }
    return self.kind == FrameSourceKindNDI ? @"ndi" : @"syphon";
}

@end

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
@property (nonatomic, readwrite, copy) NSString *error;
@property (readwrite, copy) NSString *recordingError;
@property (readwrite, copy) NSArray<RecorderPlace *> *places;
@property (readwrite, copy) NSArray<SourceDescription *> *availableSources;
@property (readwrite) NSInteger oscPort;
@property (readwrite) NSInteger oscQueryPort;
@end

@implementation RecorderController {
    id<MTLDevice> _device;
    id<SourceDirectory> _directory;
    NSUserDefaults *_defaults;
    Take *_take;
    NSArray<RecorderParameter *> *_parameters;
    NSDictionary<NSString *, RecorderParameter *> *_parametersByAddress;
    OSCReceiver *_receiver;
    BOOL _queryServerStarted;
    NSTimer *_refreshTimer;
    id<NSObject> _activity;
    NSTimeInterval _startTime;
    NSTimeInterval _lastElapsed;
    NSMutableArray<void (^)(void)> *_stopHandlers;

    // The take's pictures have a compositor of their own: one waiting to be encoded is drawn over after four
    // more, and the monitor's must not count
    Compositor *_takeCompositor;
    Compositor *_monitorCompositor;
    // Guards what follows, which the sources' threads read when a frame arrives
    os_unfair_lock _composeLock;
    NSArray<RecorderPlace *> *_composePlaces;
    LayoutKind _composeKind;
    NSInteger _composeGap;
    NSSize _composeFittingSize;
    BOOL _composeTransparent;
    // The picture of the take being recorded, if it has an assembled movie
    Layout *_takeLayout;
    // The same, as it is shown
    Layout *_takeMonitorLayout;
    BOOL _takeTransparent;
    // The place whose frames set the pace of the assembled picture
    RecorderPlace *_clockPlace;
    NSTimeInterval _lastComposeTime;
    id<MTLTexture> _assembledFrame;
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    // These are refreshed together, by -refresh
    if ([@[@"elapsed", @"frames", @"dropped", @"file", @"assembledFile", @"assembledFrames", @"assembledDropped"] containsObject:key])
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
                     directory:(id<SourceDirectory>)directory
                      defaults:(NSUserDefaults *)defaults
{
    self = [super init];
    if (self)
    {
        _device = device;
        _directory = directory;
        _defaults = defaults;
        _state = kStateIdle;
        _error = @"";
        _recordingError = @"";
        _places = @[];
        _stopHandlers = [NSMutableArray array];

        NSString *movies = NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES).firstObject;
        [defaults registerDefaults:@{
            @"RecorderCodec": [MovieRecorderSettings nameForCodec:MovieCodecH264],
            @"RecorderFolder": movies ?: NSHomeDirectory(),
            @"RecorderName": @"",
            @"RecorderOutput": [Take nameForOutput:TakeOutputSeparate],
            @"RecorderLayout": [Layout nameForKind:LayoutKindRow]
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
        TakeOutput output;
        NSString *outputName = [defaults stringForKey:@"RecorderOutput"];
        _output = [Take getOutput:&output forName:outputName] ? [outputName copy] : [Take nameForOutput:TakeOutputSeparate];
        LayoutKind kind;
        NSString *layoutName = [defaults stringForKey:@"RecorderLayout"];
        _layout = [Layout getKind:&kind forName:layoutName] ? [layoutName copy] : [Layout nameForKind:LayoutKindRow];
        _gap = MIN(MAX([defaults integerForKey:@"RecorderGap"], 0), kMaximumGap);

        _composeLock = OS_UNFAIR_LOCK_INIT;
        _composePlaces = @[];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        _takeCompositor = [[Compositor alloc] initWithCommandQueue:queue];
        _monitorCompositor = [[Compositor alloc] initWithCommandQueue:queue];

        _take = [[Take alloc] initWithDevice:device];
        __weak RecorderController *weakSelf = self;
        _take.movieFailureHandler = ^(NSUInteger index, NSError *error) {
            [weakSelf movieAtIndex:index failedWithError:error];
        };

        [self makeParameters];

        // The sources chosen when we were last used: those which are there are connected to, the others wait
        _availableSources = [self sourcesOf:directory];
        NSMutableArray<RecorderPlace *> *places = [NSMutableArray array];
        for (id title in [defaults arrayForKey:@"RecorderSources"])
        {
            if ([title isKindOfClass:[NSString class]] && [title length] > 0 && places.count < RecorderMaximumPlaces)
            {
                [places addObject:[[RecorderPlace alloc] initWithTitle:title]];
            }
        }
        _places = [places copy];
        [self connectPlaces];
        [self compositionChanged];
        directory.changeHandler = ^{
            [weakSelf sourcesDidChange];
        };

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
    for (RecorderPlace *place in _places)
    {
        [place.source stop];
    }
    [self stopNetwork];
}

- (void)changed
{
    [[NSNotificationCenter defaultCenter] postNotificationName:RecorderControllerDidChangeNotification object:self];
}

#pragma mark Settings

- (void)setCodec:(NSString *)codec
{
    _codec = [codec copy];
    [_defaults setObject:_codec forKey:@"RecorderCodec"];
    [self compositionChanged];
    [self changed];
}

- (void)setWidth:(NSInteger)width
{
    _width = MIN(MAX(width, 0), kMaximumDimension);
    [_defaults setInteger:_width forKey:@"RecorderWidth"];
    [self compositionChanged];
    [self changed];
}

- (void)setHeight:(NSInteger)height
{
    _height = MIN(MAX(height, 0), kMaximumDimension);
    [_defaults setInteger:_height forKey:@"RecorderHeight"];
    [self compositionChanged];
    [self changed];
}

- (void)setFps:(double)fps
{
    _fps = isfinite(fps) ? MIN(MAX(fps, 0.0), kMaximumFramesPerSecond) : 0.0;
    [_defaults setDouble:_fps forKey:@"RecorderFPS"];
    [self changed];
}

- (void)setBitrate:(double)bitrate
{
    _bitrate = isfinite(bitrate) ? MIN(MAX(bitrate, 0.0), kMaximumMegabitsPerSecond) : 0.0;
    [_defaults setDouble:_bitrate forKey:@"RecorderBitrate"];
    [self changed];
}

- (void)setFolder:(NSString *)folder
{
    _folder = [(folder ?: @"").stringByExpandingTildeInPath copy];
    [_defaults setObject:_folder forKey:@"RecorderFolder"];
    [self changed];
}

- (void)setName:(NSString *)name
{
    _name = [name ?: @"" copy];
    [_defaults setObject:_name forKey:@"RecorderName"];
    [self changed];
}

- (void)setOutput:(NSString *)output
{
    TakeOutput value;
    if (![Take getOutput:&value forName:output ?: @""])
    {
        return;
    }
    _output = [Take nameForOutput:value];
    [_defaults setObject:_output forKey:@"RecorderOutput"];
    [self changed];
}

- (void)setLayout:(NSString *)layout
{
    LayoutKind kind;
    if (![Layout getKind:&kind forName:layout ?: @""])
    {
        return;
    }
    _layout = [Layout nameForKind:kind];
    [_defaults setObject:_layout forKey:@"RecorderLayout"];
    [self compositionChanged];
    [self changed];
}

- (void)setGap:(NSInteger)gap
{
    _gap = MIN(MAX(gap, 0), kMaximumGap);
    [_defaults setInteger:_gap forKey:@"RecorderGap"];
    [self compositionChanged];
    [self changed];
}

- (void)setNdiAvailable:(BOOL)ndiAvailable
{
    _ndiAvailable = ndiAvailable;
    [self changed];
}

- (void)setError:(NSString *)error
{
    _error = [error copy];
    if (error.length > 0)
    {
        _errorCount++;
    }
    [self changed];
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
    return _take.assembledMovie ? self.assembledFrames : self.places.firstObject.frames;
}

- (NSUInteger)dropped
{
    NSUInteger dropped = self.assembledDropped;
    for (RecorderPlace *place in self.places)
    {
        dropped += place.dropped;
    }
    return dropped;
}

- (NSString *)file
{
    return _take.assembledMovie ? self.assembledFile : (self.places.firstObject.file ?: @"");
}

- (NSString *)assembledFile
{
    // A movie which received no picture has no file
    TakeMovie *movie = _take.assembledMovie;
    return (movie && (![self.state isEqualToString:kStateIdle] || movie.framesWritten > 0)) ? movie.url.path : @"";
}

- (NSUInteger)assembledFrames
{
    return _take.assembledMovie.framesWritten;
}

- (NSUInteger)assembledDropped
{
    return _take.assembledMovie.framesDropped;
}

// Tells observers about the values which change by themselves
- (void)refresh
{
    NSArray<NSString *> *keys = @[@"elapsed", @"frames", @"dropped", @"file", @"assembledFile", @"assembledFrames", @"assembledDropped"];
    for (NSString *key in keys)
    {
        [self willChangeValueForKey:key];
    }
    NSTimeInterval now = CACurrentMediaTime();
    for (RecorderPlace *place in self.places)
    {
        [place measureAtTime:now];
        NSTimeInterval lastFrameTime = [place lastFrameTime];
        if (lastFrameTime > place.checkTime)
        {
            // It has spoken since we last asked
            place.silentChecks = 0;
        }
        NSTimeInterval patience = MIN(kSilenceTimeout * (1 << MIN(place.silentChecks, 8)), kLongestSilenceTimeout);
        if (now - MAX(place.checkTime, lastFrameTime) <= (place.source ? patience : kSilenceTimeout))
        {
            continue;
        }
        if (place.source == nil)
        {
            // Its source may be back without the directory having said so
            [self connectPlace:place];
        }
        else if (!place.source.alive)
        {
            // A source which says nothing may have gone without the directory knowing: when an application is
            // killed, Syphon goes on listing its server, beside the one which replaces it when it is relaunched.
            // A source which is alive and silent is left alone: another with its title would be another picture.
            [place letGoOfSource];
            [self connectPlace:place];
            if (place.source)
            {
                // Connected again to something which may be as dead: NDI goes on listing a sender whose machine
                // has gone for a while. It is asked after twice as long each time, as a silent source is.
                place.silentChecks++;
            }
        }
        else
        {
            place.checkTime = now;
            place.silentChecks++;
        }
    }
    // The first place which is delivering frames sets the pace of the assembled picture
    RecorderPlace *clock = nil;
    for (RecorderPlace *place in self.places)
    {
        if (place.online)
        {
            clock = place;
            break;
        }
    }
    os_unfair_lock_lock(&_composeLock);
    if (clock)
    {
        _clockPlace = clock;
    }
    BOOL still = now - _lastComposeTime > kRefreshInterval;
    os_unfair_lock_unlock(&_composeLock);
    if (still)
    {
        // No source sets the pace: the picture is still shown as it is (a source which has gone leaves it)
        [self composeMonitorAtTime:now wait:NO];
    }
    for (NSString *key in keys.reverseObjectEnumerator)
    {
        [self didChangeValueForKey:key];
    }
    [self changed];
}

#pragma mark The assembled picture

static NSArray *SizesOfPlaces(NSArray<RecorderPlace *> *places)
{
    // The size of each source if we know it
    NSMutableArray *sizes = [NSMutableArray array];
    for (RecorderPlace *place in places)
    {
        NSInteger width = place.width, height = place.height;
        [sizes addObject:(width > 0 && height > 0) ? [NSValue valueWithSize:NSMakeSize(width, height)] : [NSNull null]];
    }
    return sizes;
}

// A layout as it is shown: the same picture, no larger than kMonitorLargestSide on a side. A picture too large to be
// recorded can still be seen, and a large one does not cost its size in memory twice.
static Layout *MonitorLayout(Layout *layout, LayoutKind kind, NSArray *sizes, NSInteger gap)
{
    NSSize size = layout.size;
    CGFloat largest = MAX(size.width, size.height);
    if (largest <= kMonitorLargestSide)
    {
        return layout;
    }
    CGFloat scale = kMonitorLargestSide / largest;
    NSSize shown = NSMakeSize(MAX(round(size.width * scale / 2.0) * 2.0, 2.0), MAX(round(size.height * scale / 2.0) * 2.0, 2.0));
    return [[Layout alloc] initWithKind:kind sourceSizes:sizes gap:gap fittingSize:shown];
}

- (LayoutKind)layoutKind
{
    LayoutKind kind = LayoutKindRow;
    [Layout getKind:&kind forName:self.layout];
    return kind;
}

- (Layout *)assembledLayout
{
    os_unfair_lock_lock(&_composeLock);
    Layout *layout = _takeLayout;
    os_unfair_lock_unlock(&_composeLock);
    return layout ?: [[Layout alloc] initWithKind:[self layoutKind]
                                      sourceSizes:SizesOfPlaces(self.places)
                                              gap:self.gap
                                      fittingSize:NSMakeSize(self.width, self.height)];
}

- (id<MTLTexture>)assembledFrame
{
    os_unfair_lock_lock(&_composeLock);
    id<MTLTexture> frame = _assembledFrame;
    os_unfair_lock_unlock(&_composeLock);
    return frame;
}

// Main thread: the places or the settings which make the picture have changed
- (void)compositionChanged
{
    NSArray<RecorderPlace *> *places = self.places;
    MovieCodec codec = MovieCodecH264;
    [MovieRecorderSettings getCodec:&codec forName:self.codec];
    os_unfair_lock_lock(&_composeLock);
    _composePlaces = places;
    _composeKind = [self layoutKind];
    _composeGap = self.gap;
    _composeFittingSize = NSMakeSize(self.width, self.height);
    // The picture is shown as it would be recorded
    _composeTransparent = codec == MovieCodecProRes4444;
    if (_clockPlace && ![places containsObject:_clockPlace])
    {
        _clockPlace = nil;
    }
    os_unfair_lock_unlock(&_composeLock);
    // Shown at once: a picture which does not move sends no frame
    [self composeMonitorAtTime:CACurrentMediaTime() wait:YES];
}

// Any thread. Composes the picture of the places as they are now. Once it is drawn it is the picture shown, and
// handler is given it (on a thread of Metal's): only then can it be read with another command queue, as a movie's is.
// NO if there is no picture: handler is not called.
- (BOOL)composePlaces:(NSArray<RecorderPlace *> *)places
               layout:(Layout *)layout
          transparent:(BOOL)transparent
                 with:(Compositor *)compositor
               atTime:(NSTimeInterval)time
                 then:(void (^)(id<MTLTexture> picture))handler
{
    NSMutableArray *textures = [NSMutableArray array];
    NSMutableArray<NSNumber *> *flipped = [NSMutableArray array];
    for (RecorderPlace *place in places)
    {
        // A source which is away leaves its place empty. One which is there and silent (a picture which does not
        // move) keeps its last frame.
        id<MTLTexture> frame = place.source ? place.latestFrame : nil;
        [textures addObject:frame ? (id)frame : [NSNull null]];
        [flipped addObject:@(place.flipped)];
    }
    os_unfair_lock_lock(&_composeLock);
    _lastComposeTime = time;
    os_unfair_lock_unlock(&_composeLock);

    __weak RecorderController *weakSelf = self;
    id<MTLTexture> picture = places.count == 0 ? nil : [compositor compose:layout textures:textures flipped:flipped transparent:transparent
                                                              completionHandler:^(id<MTLTexture> drawn) {
        [weakSelf showPicture:drawn];
        if (handler)
        {
            handler(drawn);
        }
    }];
    if (picture == nil)
    {
        // No source, or a picture too large to be composed: there is nothing to show
        [self showPicture:nil];
    }
    return picture != nil;
}

- (void)showPicture:(id<MTLTexture>)picture
{
    os_unfair_lock_lock(&_composeLock);
    _assembledFrame = picture;
    os_unfair_lock_unlock(&_composeLock);
}

// Any thread. Composes the picture to show it: that of the take if one is recorded to an assembled movie.
// wait: return once the picture is drawn.
- (void)composeMonitorAtTime:(NSTimeInterval)time wait:(BOOL)wait
{
    os_unfair_lock_lock(&_composeLock);
    NSArray<RecorderPlace *> *places = _composePlaces;
    Layout *layout = _takeMonitorLayout;
    BOOL transparent = layout ? _takeTransparent : _composeTransparent;
    LayoutKind kind = _composeKind;
    NSInteger gap = _composeGap;
    NSSize fittingSize = _composeFittingSize;
    os_unfair_lock_unlock(&_composeLock);
    if (layout == nil)
    {
        NSArray *sizes = SizesOfPlaces(places);
        layout = MonitorLayout([[Layout alloc] initWithKind:kind sourceSizes:sizes gap:gap fittingSize:fittingSize], kind, sizes, gap);
    }
    dispatch_semaphore_t drawn = wait ? dispatch_semaphore_create(0) : nil;
    BOOL composed = [self composePlaces:places layout:layout transparent:transparent with:_monitorCompositor atTime:time then:^(id<MTLTexture> picture) {
        if (drawn)
        {
            dispatch_semaphore_signal(drawn);
        }
    }];
    if (drawn && composed)
    {
        dispatch_semaphore_wait(drawn, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)));
    }
}

// Called on a source's own thread, when a frame has arrived in its place
- (void)place:(RecorderPlace *)place receivedFrameAtTime:(NSTimeInterval)time
{
    os_unfair_lock_lock(&_composeLock);
    if (![_composePlaces containsObject:place])
    {
        os_unfair_lock_unlock(&_composeLock);
        return;
    }
    // The pace is set by the first place which is delivering frames (-refresh sees to it). If that place has
    // stopped, the next to deliver takes over without waiting to be told.
    if (_clockPlace != place && (_clockPlace == nil || time - [_clockPlace lastFrameTime] > kOnlineTimeout))
    {
        _clockPlace = place;
    }
    BOOL setsThePace = _clockPlace == place;
    NSArray<RecorderPlace *> *places = _composePlaces;
    Layout *takeLayout = _takeLayout;
    BOOL transparent = _takeTransparent;
    BOOL monitorIsDue = time - _lastComposeTime >= kMonitorInterval;
    os_unfair_lock_unlock(&_composeLock);
    if (!setsThePace)
    {
        return;
    }

    if (takeLayout && [_take wantsAssembledFrameAtTime:time])
    {
        Take *take = _take;
        [self composePlaces:places layout:takeLayout transparent:transparent with:_takeCompositor atTime:time then:^(id<MTLTexture> picture) {
            [take appendAssembledTexture:picture atTime:time];
        }];
    }
    else if (monitorIsDue)
    {
        [self composeMonitorAtTime:time wait:NO];
    }
}

#pragma mark Places

// The directory's sources, each title once: a title is what a source is known by
- (NSArray<SourceDescription *> *)sourcesOf:(id<SourceDirectory>)directory
{
    NSMutableArray<SourceDescription *> *sources = [NSMutableArray array];
    NSMutableSet<NSString *> *titles = [NSMutableSet set];
    for (SourceDescription *source in [directory availableSources])
    {
        if (![titles containsObject:source.title])
        {
            [titles addObject:source.title];
            [sources addObject:source];
        }
    }
    return sources;
}

// Connects the places whose source is there, and lets go of those whose source has gone
- (void)connectPlaces
{
    NSMutableSet<NSString *> *available = [NSMutableSet set];
    for (SourceDescription *source in self.availableSources)
    {
        [available addObject:source.title];
    }
    for (RecorderPlace *place in self.places)
    {
        BOOL there = [available containsObject:place.title];
        if (place.source && !there)
        {
            [place letGoOfSource];
        }
        else if (place.source == nil && there)
        {
            [self connectPlace:place];
        }
    }
}

- (void)connectPlace:(RecorderPlace *)place
{
    place.checkTime = CACurrentMediaTime();
    id<FrameSource> source = [_directory connectToSourceWithTitle:place.title device:_device];
    if (source == nil)
    {
        return;
    }
    // Its kind is that of the source connected to: Syphon may list the title and have nothing alive with it
    place.kind = source.kind;
    place.kindKnown = YES;
    BOOL flipped = source.flipped;
    Take *take = _take;
    __weak RecorderController *weakSelf = self;
    __weak RecorderPlace *weakPlace = place;
    // Called on the source's own thread: the frame goes to the place, which shows it, and to the place's movie if
    // a take is being recorded
    source.frameHandler = ^(id<MTLTexture> frame) {
        RecorderPlace *strongPlace = weakPlace;
        if (strongPlace == nil)
        {
            return;
        }
        NSTimeInterval now = CACurrentMediaTime();
        NSUInteger index = [strongPlace receivedFrame:frame flipped:flipped atTime:now];
        if (index != NSNotFound)
        {
            [take appendTexture:frame flipped:flipped fromSourceAtIndex:index atTime:now];
        }
        [weakSelf place:strongPlace receivedFrameAtTime:now];
    };
    place.source = source;
}

// The places are these from now on: saved, and told
- (void)usePlaces:(NSArray<RecorderPlace *> *)places
{
    for (RecorderPlace *place in self.places)
    {
        if (![places containsObject:place])
        {
            [place letGoOfSource];
        }
    }
    self.places = places;
    [_defaults setObject:[places valueForKey:@"title"] forKey:@"RecorderSources"];
    [self connectPlaces];
    [self compositionChanged];
    [self changed];
}

- (BOOL)placesCanChange
{
    if (![self.state isEqualToString:kStateIdle])
    {
        return [self failWithError:@"The sources cannot be changed while recording"];
    }
    return YES;
}

// The title of the source meant: this title or, failing that, the first which contains it, whatever the case
- (NSString *)titleMatching:(NSString *)title
{
    if (title.length == 0)
    {
        [self failWithError:@"/source expects the title of a source"];
        return nil;
    }
    // The sources available and, as a source which is away keeps its place, those chosen
    NSMutableArray<NSString *> *titles = [[self.availableSources valueForKey:@"title"] mutableCopy];
    for (RecorderPlace *place in self.places)
    {
        if (![titles containsObject:place.title])
        {
            [titles addObject:place.title];
        }
    }
    NSUInteger index = [titles indexOfObject:title];
    if (index == NSNotFound)
    {
        index = [titles indexOfObjectPassingTest:^BOOL(NSString *candidate, NSUInteger idx, BOOL *stop) {
            return [candidate rangeOfString:title options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
    }
    if (index == NSNotFound)
    {
        [self failWithError:[NSString stringWithFormat:@"There is no source called “%@”", title]];
        return nil;
    }
    return titles[index];
}

- (NSUInteger)indexOfPlaceWithTitle:(NSString *)title
{
    return [self.places indexOfObjectPassingTest:^BOOL(RecorderPlace *place, NSUInteger idx, BOOL *stop) {
        return [place.title isEqualToString:title];
    }];
}

- (BOOL)addSourceMatching:(NSString *)title
{
    if (![self placesCanChange])
    {
        return NO;
    }
    NSString *found = [self titleMatching:title];
    if (found == nil)
    {
        return NO;
    }
    if ([self indexOfPlaceWithTitle:found] != NSNotFound)
    {
        return YES;
    }
    if (self.places.count >= RecorderMaximumPlaces)
    {
        return [self failWithError:[NSString stringWithFormat:@"No more than %lu sources can be recorded at once", (unsigned long)RecorderMaximumPlaces]];
    }
    [self usePlaces:[self.places arrayByAddingObject:[[RecorderPlace alloc] initWithTitle:found]]];
    return YES;
}

- (BOOL)setSourceMatching:(NSString *)title atPlace:(NSUInteger)place
{
    if (![self placesCanChange])
    {
        return NO;
    }
    if (place < 1 || place > RecorderMaximumPlaces)
    {
        return [self failWithError:[NSString stringWithFormat:@"There are places 1 to %lu", (unsigned long)RecorderMaximumPlaces]];
    }
    if (title.length == 0)
    {
        [self removeSourceAtPlace:place];
        return YES;
    }
    NSString *found = [self titleMatching:title];
    if (found == nil)
    {
        return NO;
    }

    NSMutableArray<RecorderPlace *> *places = [self.places mutableCopy];
    NSUInteger index = place - 1;
    NSUInteger current = [self indexOfPlaceWithTitle:found];
    if (current != NSNotFound)
    {
        // Chosen already: it moves, with its connection
        RecorderPlace *moving = places[current];
        [places removeObjectAtIndex:current];
        [places insertObject:moving atIndex:MIN(index, places.count)];
    }
    else if (index < places.count)
    {
        places[index] = [[RecorderPlace alloc] initWithTitle:found];
    }
    else
    {
        [places addObject:[[RecorderPlace alloc] initWithTitle:found]];
    }
    [self usePlaces:places];
    return YES;
}

- (void)removeSourceAtPlace:(NSUInteger)place
{
    if (![self placesCanChange] || place < 1 || place > self.places.count)
    {
        return;
    }
    NSMutableArray<RecorderPlace *> *places = [self.places mutableCopy];
    [places removeObjectAtIndex:place - 1];
    [self usePlaces:places];
}

- (BOOL)moveSourceFromPlace:(NSUInteger)from toPlace:(NSUInteger)to
{
    if (![self placesCanChange])
    {
        return NO;
    }
    if (from < 1 || from > self.places.count || to < 1)
    {
        return [self failWithError:@"There is no source in that place"];
    }
    NSMutableArray<RecorderPlace *> *places = [self.places mutableCopy];
    RecorderPlace *moving = places[from - 1];
    [places removeObjectAtIndex:from - 1];
    [places insertObject:moving atIndex:MIN(to - 1, places.count)];
    [self usePlaces:places];
    return YES;
}

// The directory's sources have changed
- (void)sourcesDidChange
{
    self.availableSources = [self sourcesOf:_directory];
    // A source which has gone keeps its place, and is connected to again when it is back
    [self connectPlaces];
    if (_queryServerStarted)
    {
        // The sources available are the values a place can take
        for (RecorderParameter *parameter in _parameters)
        {
            if ([parameter.address hasPrefix:@"/source"])
            {
                [self registerParameter:parameter];
            }
        }
    }
    [self changed];
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
        // Already recording: there is nothing to do. Finishing: the movies must be finished first.
        return [self.state isEqualToString:kStateRecording] ? YES : [self failWithError:@"The previous recording is still being finished"];
    }
    self.error = @"";
    self.recordingError = @"";

    NSArray<RecorderPlace *> *places = self.places;
    if (places.count == 0)
    {
        return [self failWithError:@"No source is selected"];
    }

    MovieRecorderSettings *settings = [[MovieRecorderSettings alloc] init];
    MovieCodec codec = MovieCodecH264;
    [MovieRecorderSettings getCodec:&codec forName:self.codec];
    settings.codec = codec;
    settings.framesPerSecond = self.fps;
    settings.megabitsPerSecond = self.bitrate;

    // The size of each source if we know it, so that its movie is ready for its first frame
    NSArray *sizes = SizesOfPlaces(places);

    // The assembled picture is that of the sources as they are now, and stays so for the take
    TakeOutput output = TakeOutputSeparate;
    [Take getOutput:&output forName:self.output];
    Layout *layout = nil;
    if (output != TakeOutputSeparate)
    {
        layout = [[Layout alloc] initWithKind:[self layoutKind] sourceSizes:sizes gap:self.gap fittingSize:NSMakeSize(self.width, self.height)];
    }

    NSString *name = self.name;
    if (name.length == 0)
    {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH.mm.ss";
        name = [NSString stringWithFormat:@"Simple Recorder %@", [formatter stringFromDate:[NSDate date]]];
    }

    NSTimeInterval now = CACurrentMediaTime();
    NSError *error = nil;
    if (![_take startWithSourceTitles:[places valueForKey:@"title"]
                                sizes:sizes
                               output:output
                        assembledSize:layout ? layout.size : NSZeroSize
                                 name:name
                               folder:[NSURL fileURLWithPath:self.folder isDirectory:YES]
                             settings:settings
                               atTime:now
                                error:&error])
    {
        return [self failWithError:error.localizedDescription ?: @"The recording could not start"];
    }

    // Assembled alone, the places have no movie
    NSArray<TakeMovie *> *movies = _take.movies;
    [places enumerateObjectsUsingBlock:^(RecorderPlace *place, NSUInteger index, BOOL *stop) {
        BOOL hasMovie = index < movies.count;
        place.movie = hasMovie ? movies[index] : nil;
        place.inTake = hasMovie;
        [place setTakeIndex:hasMovie ? index : NSNotFound];
    }];
    os_unfair_lock_lock(&_composeLock);
    _takeLayout = layout;
    _takeMonitorLayout = layout ? MonitorLayout(layout, [self layoutKind], sizes, self.gap) : nil;
    _takeTransparent = codec == MovieCodecProRes4444;
    os_unfair_lock_unlock(&_composeLock);

    _startTime = now;
    // Not to be slowed down or put to sleep while we record
    _activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                                                               reason:@"Recording"];
    self.state = kStateRecording;
    [self refresh];
    return YES;
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
    for (RecorderPlace *place in self.places)
    {
        [place setTakeIndex:NSNotFound];
    }
    os_unfair_lock_lock(&_composeLock);
    _takeLayout = nil;
    _takeMonitorLayout = nil;
    os_unfair_lock_unlock(&_composeLock);
    self.state = kStateFinishing;
    [self changed];
    __weak RecorderController *weakSelf = self;
    [_take finishAtTime:now completionHandler:^(NSError *error) {
        [weakSelf recordingEndedWithError:error];
    }];
}

// Every movie of the take: the sources', then the assembled one
- (NSArray<TakeMovie *> *)moviesOfTheTake
{
    TakeMovie *assembled = _take.assembledMovie;
    return assembled ? [_take.movies arrayByAddingObject:assembled] : _take.movies;
}

// One movie has failed (a full disk, for instance): the others go on, unless none is left. index is NSNotFound
// for the assembled movie.
- (void)movieAtIndex:(NSUInteger)index failedWithError:(NSError *)error
{
    NSArray<TakeMovie *> *movies = [self moviesOfTheTake];
    NSString *title = index < _take.movies.count ? _take.movies[index].sourceTitle : kAssembledMovieTitle;
    NSString *message = movies.count > 1 ? [NSString stringWithFormat:@"%@: %@", title, error.localizedDescription] : error.localizedDescription;
    self.error = message;
    self.recordingError = message;

    BOOL someGoOn = NO;
    for (TakeMovie *movie in movies)
    {
        someGoOn = someGoOn || movie.error == nil;
    }
    if (!someGoOn)
    {
        [self stopWithCompletionHandler:nil];
    }
}

// The movies are finished
- (void)recordingEndedWithError:(NSError *)error
{
    if ([self.state isEqualToString:kStateIdle])
    {
        return;
    }
    for (RecorderPlace *place in self.places)
    {
        place.inTake = NO;
    }
    // A movie which failed during the take has said why already. One may also have failed as it was finished.
    if (self.recordingError.length == 0)
    {
        NSArray<TakeMovie *> *movies = [self moviesOfTheTake];
        NSString *message = error.localizedDescription;
        for (TakeMovie *movie in movies)
        {
            if (message == nil && movie.error)
            {
                NSString *title = movie.sourceTitle.length > 0 ? movie.sourceTitle : kAssembledMovieTitle;
                message = movies.count > 1 ? [NSString stringWithFormat:@"%@: %@", title, movie.error.localizedDescription] : movie.error.localizedDescription;
            }
        }
        if (message)
        {
            self.error = message;
            self.recordingError = message;
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

#pragma mark Parameters

- (RecorderParameter *)parameter:(NSString *)address type:(NSString *)typeSpec summary:(NSString *)summary
{
    RecorderParameter *parameter = [[RecorderParameter alloc] init];
    parameter.address = address;
    parameter.typeSpec = typeSpec;
    parameter.summary = summary;
    return parameter;
}

// A number which is read with one key and set with it
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

// The source in a place (from 1)
- (RecorderParameter *)placeParameter:(NSString *)address place:(NSUInteger)place summary:(NSString *)summary
{
    __weak RecorderController *weakSelf = self;
    RecorderParameter *parameter = [self parameter:address type:@"s" summary:summary];
    parameter.range = ^{
        // Each title once: of sources with the same title, the first is chosen
        NSArray<NSString *> *titles = [weakSelf.availableSources valueForKey:@"title"] ?: @[];
        return @[@{@"VALS": [[NSOrderedSet orderedSetWithArray:titles] array]}];
    };
    parameter.get = ^{
        NSArray<RecorderPlace *> *places = weakSelf.places;
        return @[place <= places.count ? places[place - 1].title : @""];
    };
    parameter.set = ^NSString *(NSArray *arguments) {
        NSString *title = StringFrom(arguments);
        if (title == nil)
        {
            return @"expects the title of a source, or an empty string";
        }
        // It reports its own errors
        [weakSelf setSourceMatching:title atPlace:place];
        return nil;
    };
    return parameter;
}

// Something a place tells (key is a key of RecorderPlace)
- (RecorderParameter *)placeStatusParameter:(NSString *)name place:(NSUInteger)place type:(NSString *)typeSpec summary:(NSString *)summary key:(NSString *)key
{
    __weak RecorderController *weakSelf = self;
    RecorderParameter *parameter = [self parameter:[NSString stringWithFormat:@"/status/source/%lu/%@", (unsigned long)place, name] type:typeSpec summary:summary];
    BOOL isString = [typeSpec isEqualToString:@"s"];
    parameter.get = ^{
        NSArray<RecorderPlace *> *places = weakSelf.places;
        id value = place <= places.count ? [places[place - 1] valueForKey:key] : nil;
        if ([typeSpec isEqualToString:@"i"] && [value isKindOfClass:[NSNumber class]])
        {
            // A yes or no is an OSC int here, not a JSON true or false
            value = @([value integerValue]);
        }
        return @[value ?: (isString ? @"" : @0)];
    };
    return parameter;
}

- (void)makeParameters
{
    __weak RecorderController *weakSelf = self;
    NSMutableArray<RecorderParameter *> *parameters = [NSMutableArray array];

    [parameters addObject:[self placeParameter:@"/source" place:1 summary:@"The first source to record: its title, or part of it. The same as /source/1."]];
    for (NSUInteger place = 1; place <= RecorderMaximumPlaces; place++)
    {
        NSString *summary = [NSString stringWithFormat:@"Source %lu to record: its title, or part of it. Empty for none: the sources after it move up.", (unsigned long)place];
        [parameters addObject:[self placeParameter:[NSString stringWithFormat:@"/source/%lu", (unsigned long)place] place:place summary:summary]];
    }

    RecorderParameter *record = [self parameter:@"/record" type:@"i" summary:@"1 starts recording the sources, 0 stops and finishes the movies"];
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
    [parameters addObject:record];

    RecorderParameter *toggle = [self parameter:@"/record/toggle" type:nil summary:@"Starts recording, or stops"];
    toggle.set = ^NSString *(NSArray *arguments) {
        [weakSelf toggle];
        return nil;
    };
    [parameters addObject:toggle];

    RecorderParameter *codec = [self parameter:@"/codec" type:@"s" summary:@"The codec of the movies. prores4444 keeps transparency."];
    codec.range = ^{ return @[@{@"VALS": [MovieRecorderSettings codecNames]}]; };
    codec.get = ^{ return @[weakSelf.codec ?: @""]; };
    codec.set = ^NSString *(NSArray *arguments) {
        NSString *name = StringFrom(arguments).lowercaseString;
        MovieCodec value;
        if (name == nil || ![MovieRecorderSettings getCodec:&value forName:name])
        {
            return [NSString stringWithFormat:@"“%@” is not one of %@", arguments.firstObject ?: @"",
                    [[MovieRecorderSettings codecNames] componentsJoinedByString:@", "]];
        }
        weakSelf.codec = name;
        return nil;
    };
    [parameters addObject:codec];

    RecorderParameter *output = [self parameter:@"/output" type:@"s" summary:@"What a recording writes: separate (a movie for each source), assembled (one movie of the sources together), or both"];
    output.range = ^{ return @[@{@"VALS": [Take outputNames]}]; };
    output.get = ^{ return @[weakSelf.output ?: @""]; };
    output.set = ^NSString *(NSArray *arguments) {
        TakeOutput value;
        NSString *name = StringFrom(arguments);
        if (name == nil || ![Take getOutput:&value forName:name])
        {
            return [NSString stringWithFormat:@"“%@” is not one of %@", arguments.firstObject ?: @"", [[Take outputNames] componentsJoinedByString:@", "]];
        }
        weakSelf.output = name;
        return nil;
    };
    [parameters addObject:output];

    RecorderParameter *layout = [self parameter:@"/layout" type:@"s" summary:@"How the sources are assembled, in their order: row (side by side), column (stacked), grid (a mosaic), focus (the first large, the others beside it)"];
    layout.range = ^{ return @[@{@"VALS": [Layout kindNames]}]; };
    layout.get = ^{ return @[weakSelf.layout ?: @""]; };
    layout.set = ^NSString *(NSArray *arguments) {
        LayoutKind kind;
        NSString *name = StringFrom(arguments);
        if (name == nil || ![Layout getKind:&kind forName:name])
        {
            return [NSString stringWithFormat:@"“%@” is not one of %@", arguments.firstObject ?: @"", [[Layout kindNames] componentsJoinedByString:@", "]];
        }
        weakSelf.layout = name;
        return nil;
    };
    [parameters addObject:layout];

    RecorderParameter *assembledWidth = [self parameter:@"/status/assembled/width" type:@"i" summary:@"Width of the assembled picture as it is now, or of the take being recorded"];
    assembledWidth.get = ^{ return @[@(weakSelf.places.count > 0 ? (NSInteger)weakSelf.assembledLayout.size.width : 0)]; };
    RecorderParameter *assembledHeight = [self parameter:@"/status/assembled/height" type:@"i" summary:@"Height of the assembled picture as it is now, or of the take being recorded"];
    assembledHeight.get = ^{ return @[@(weakSelf.places.count > 0 ? (NSInteger)weakSelf.assembledLayout.size.height : 0)]; };

    [parameters addObjectsFromArray:@[
        [self numberParameter:@"/gap" type:@"i" summary:@"Pixels between the sources in the assembled picture" key:@"gap" maximum:kMaximumGap],
        assembledWidth,
        assembledHeight,
        [self statusParameter:@"/status/assembled/file" type:@"s" summary:@"The assembled movie, being written or last written. Empty if there is none." key:@"assembledFile"],
        [self statusParameter:@"/status/assembled/frames" type:@"i" summary:@"Frames written to the assembled movie" key:@"assembledFrames"],
        [self statusParameter:@"/status/assembled/dropped" type:@"i" summary:@"Pictures lost because the encoder of the assembled movie could not keep up" key:@"assembledDropped"],
        [self numberParameter:@"/width" type:@"i" summary:@"Width the assembled picture is fitted into, in pixels. 0 (or a height of 0) for the size the sources need. A source's own movie is the size of the source."
                          key:@"width" maximum:kMaximumDimension],
        [self numberParameter:@"/height" type:@"i" summary:@"Height the assembled picture is fitted into, in pixels. 0 (or a width of 0) for the size the sources need. A source's own movie is the size of the source."
                          key:@"height" maximum:kMaximumDimension],
        [self numberParameter:@"/fps" type:@"f" summary:@"The most frames the movies have each second. 0 keeps every frame of the sources."
                          key:@"fps" maximum:kMaximumFramesPerSecond],
        [self numberParameter:@"/bitrate" type:@"f" summary:@"Megabits per second for h264 and hevc. 0 chooses from the size and frame rate."
                          key:@"bitrate" maximum:kMaximumMegabitsPerSecond],
        [self stringParameter:@"/folder" summary:@"The folder movies are written to" key:@"folder"],
        [self stringParameter:@"/name" summary:@"The name of the recording, without extension: the assembled movie's. Empty for the app's name and the date. A source's own movie adds its source's title, unless it is the only movie."
                          key:@"name"],
        [self statusParameter:@"/status/state" type:@"s" summary:@"idle, recording, or finishing while the movies are completed" key:@"state"],
        [self statusParameter:@"/status/elapsed" type:@"f" summary:@"Seconds recorded" key:@"elapsed"],
        [self statusParameter:@"/status/frames" type:@"i" summary:@"Frames written to the assembled movie or, if there is none, to the first source's" key:@"frames"],
        [self statusParameter:@"/status/dropped" type:@"i" summary:@"Frames lost in all the movies because the encoder could not keep up" key:@"dropped"],
        [self statusParameter:@"/status/file" type:@"s" summary:@"The assembled movie or, if there is none, the first source's: being written or last written" key:@"file"],
        [self statusParameter:@"/status/error" type:@"s" summary:@"The last error. Empty when a recording starts." key:@"error"],
        [self statusParameter:@"/status/failure" type:@"s" summary:@"Why the last recording ended, if it failed or had nothing to write. Empty otherwise."
                          key:@"recordingError"]
    ]];

    RecorderParameter *ndi = [self parameter:@"/status/ndi" type:@"i" summary:@"1 if NDI is available: its library is installed. Without it there are no NDI sources, which is not an error."];
    // An OSC int, not a JSON true or false
    ndi.get = ^{ return @[@(weakSelf.ndiAvailable ? 1 : 0)]; };
    RecorderParameter *ndiSources = [self parameter:@"/status/ndi/sources" type:@"s" summary:@"The titles of the NDI sources available, one per line: the other sources are Syphon's"];
    ndiSources.get = ^{
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (SourceDescription *source in weakSelf.availableSources)
        {
            if (source.kind == FrameSourceKindNDI)
            {
                [titles addObject:source.title];
            }
        }
        return @[[titles componentsJoinedByString:@"\n"]];
    };
    [parameters addObjectsFromArray:@[ndi, ndiSources]];

    for (NSUInteger place = 1; place <= RecorderMaximumPlaces; place++)
    {
        [parameters addObjectsFromArray:@[
            [self placeStatusParameter:@"online" place:place type:@"i" summary:@"1 if the source is delivering frames" key:@"online"],
            [self placeStatusParameter:@"width" place:place type:@"i" summary:@"Width of the source's frames" key:@"width"],
            [self placeStatusParameter:@"height" place:place type:@"i" summary:@"Height of the source's frames" key:@"height"],
            [self placeStatusParameter:@"fps" place:place type:@"f" summary:@"Frames the source delivers each second" key:@"fps"],
            [self placeStatusParameter:@"file" place:place type:@"s" summary:@"The source's movie, being written or last written" key:@"file"],
            [self placeStatusParameter:@"frames" place:place type:@"i" summary:@"Frames written to the source's movie" key:@"frames"],
            [self placeStatusParameter:@"dropped" place:place type:@"i" summary:@"Frames of the source lost because the encoder could not keep up" key:@"dropped"],
            [self placeStatusParameter:@"kind" place:place type:@"s" summary:@"What the source is: syphon or ndi. Empty until it has been connected to." key:@"kindName"]
        ]];
    }

    _parameters = parameters;
    NSMutableDictionary *byAddress = [NSMutableDictionary dictionary];
    for (RecorderParameter *parameter in _parameters)
    {
        byAddress[parameter.address] = parameter;
    }
    _parametersByAddress = byAddress;
}

- (void)handleMessage:(OSCMessage *)message
{
    RecorderParameter *parameter = _parametersByAddress[message.address];
    if (parameter == nil)
    {
        // Said rather than ignored: an address which is not quite right is the usual reason "nothing happens"
        self.error = [NSString stringWithFormat:@"There is no OSC address “%@”", message.address];
        return;
    }
    if (parameter.set == nil)
    {
        self.error = [NSString stringWithFormat:@"%@ can only be read", message.address];
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
    [self changed];
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
