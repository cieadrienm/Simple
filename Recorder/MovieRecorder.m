/*
 MovieRecorder.m
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

#import "MovieRecorder.h"
#import "FramePacer.h"
#import "SourceSound.h"
#import "SoundTimeline.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

NSString * const MovieRecorderErrorDomain = @"net.am-cb.simple.MovieRecorder";

// Frames waiting for the GPU or the encoder beyond which new ones are dropped
static const NSUInteger kMaximumFramesPending = 3;
static const int32_t kTimescale = 60000;
// How long a frame waits for an encoder which is not ready for it before it is dropped
static const int kEncoderWaitMilliseconds = 500;
// The frame rate assumed for choosing a bitrate when the recording has no maximum
static const double kAssumedFramesPerSecond = 60.0;
// The sound track's rate: the encoder is given nothing else
static const double kSoundRate = 48000.0;
// Seconds of sound which may wait for the encoder: beyond, the oldest is left out
static const NSTimeInterval kMaximumSoundWaiting = 2.0;
// The same while silence is owed for a gap: the encoder takes about 340 s of AAC silence a second, so an hour's gap
// keeps the sound which comes back waiting for some ten seconds, which must not be left out
static const NSTimeInterval kMaximumSoundWaitingBehindSilence = 30.0;
// How long finishing waits for an encoder which takes nothing more
static const int kSoundFinishWaitMilliseconds = 1000;
// The most silence given to the encoder at once, in samples of the sound track: a long gap is given a second at a
// time, so that it never holds the pictures back
static const int64_t kLongestSilenceWritten = 48000;

static NSString * const kShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
struct Vertex {\n\
    float4 position [[position]];\n\
    float2 texCoord;\n\
};\n\
vertex Vertex frameVertex(uint vertexID [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {\n\
    Vertex out;\n\
    out.position = float4(vertices[vertexID].xy, 0.0, 1.0);\n\
    out.texCoord = vertices[vertexID].zw;\n\
    return out;\n\
}\n\
fragment float4 frameFragment(Vertex in [[stage_in]], texture2d<float> frame [[texture(0)]]) {\n\
    constexpr sampler linear(filter::linear, address::clamp_to_edge);\n\
    return frame.sample(linear, in.texCoord);\n\
}\n";

static NSError *RecorderError(NSString *description)
{
    return [NSError errorWithDomain:MovieRecorderErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: description}];
}

// A piece of sound which waits for the encoder, with the time it arrived
@interface WaitingSound : NSObject
@property (strong) SourceSound *sound;
@property (assign) NSTimeInterval time;
@end

@implementation WaitingSound
@end

@implementation MovieRecorderSettings

+ (NSArray<NSString *> *)codecNames
{
    return @[@"h264", @"hevc", @"prores422", @"prores4444"];
}

+ (NSString *)nameForCodec:(MovieCodec)codec
{
    NSArray<NSString *> *names = [self codecNames];
    return (codec >= 0 && codec < (NSInteger)names.count) ? names[codec] : names[0];
}

+ (BOOL)getCodec:(MovieCodec *)codec forName:(NSString *)name
{
    NSUInteger index = [[self codecNames] indexOfObject:name.lowercaseString];
    if (index == NSNotFound)
    {
        return NO;
    }
    *codec = (MovieCodec)index;
    return YES;
}

- (id)copyWithZone:(NSZone *)zone
{
    MovieRecorderSettings *copy = [[MovieRecorderSettings alloc] init];
    copy.codec = self.codec;
    copy.width = self.width;
    copy.height = self.height;
    copy.framesPerSecond = self.framesPerSecond;
    copy.megabitsPerSecond = self.megabitsPerSecond;
    copy.recordsSound = self.recordsSound;
    return copy;
}

@end

@implementation MovieRecorder {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    CVMetalTextureCacheRef _textureCache;

    // Everything about the file being written is used on this queue only
    dispatch_queue_t _queue;
    dispatch_group_t _framesInFlight;
    NSURL *_url;
    MovieRecorderSettings *_settings;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    CMTime _lastTime;
    // The sound track, if the movie has one
    AVAssetWriterInput *_audioInput;
    CMAudioFormatDescriptionRef _soundFormat;
    // Made when the movie's time 0 is known
    SoundTimeline *_soundTimeline;
    // The rate of the sound being placed, and the converter to 48 kHz if it is another
    double _soundRate;
    AVAudioConverter *_converter;
    // Placed, waiting for the encoder: sound at 48 kHz (SourceSound), and silence still owed (NSNumber, a count of
    // 48 kHz samples: it is made only as it is written). Holds what one piece of sound gave at most.
    NSMutableArray *_placedSound;
    // The sound track's next sample
    int64_t _soundPosition;

    // Guards what follows, which is used from the threads frames arrive on
    os_unfair_lock _lock;
    BOOL _recording;
    // From the end of a recording until its last frames have left and its file is finished: no other can start
    BOOL _finishing;
    FramePacer *_pacer;
    BOOL _hasFirstFrame;
    NSTimeInterval _firstFrameTime;
    NSUInteger _framesWritten;
    NSUInteger _framesDropped;
    NSUInteger _framesPending;
    NSSize _outputSize;
    BOOL _recordsSound;
    // Sound which has arrived and waits to be placed and given to the encoder: kMaximumSoundWaiting at most
    NSMutableArray<WaitingSound *> *_waitingSound;
    NSTimeInterval _soundWaiting;
    BOOL _soundWriteScheduled;
    // Silence is owed for a gap, or more than kMaximumSoundWaiting of sound still waits behind it: the sound which
    // waits may reach kMaximumSoundWaitingBehindSilence
    BOOL _soundBehindGap;
    NSTimeInterval _soundWritten;
    NSTimeInterval _soundLeftOut;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self)
    {
        _device = device;
        _commandQueue = [device newCommandQueue];
        _queue = dispatch_queue_create("net.am-cb.simple.movie-recorder", DISPATCH_QUEUE_SERIAL);
        _framesInFlight = dispatch_group_create();
        _lock = OS_UNFAIR_LOCK_INIT;
        _placedSound = [NSMutableArray array];
        _waitingSound = [NSMutableArray array];

        // What the encoder is given: 48 kHz, two channels of interleaved floats
        AudioStreamBasicDescription description = {
            .mSampleRate = kSoundRate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 2 * sizeof(float),
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2 * sizeof(float),
            .mChannelsPerFrame = 2,
            .mBitsPerChannel = 32
        };
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &description, 0, NULL, 0, NULL, NULL, &_soundFormat);

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:kShaderSource options:nil error:&error];
        if (library)
        {
            MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
            descriptor.vertexFunction = [library newFunctionWithName:@"frameVertex"];
            descriptor.fragmentFunction = [library newFunctionWithName:@"frameFragment"];
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);
        if (_pipeline == nil || _textureCache == NULL || _soundFormat == NULL)
        {
            NSLog(@"MovieRecorder could not be created: %@", error);
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    if (_textureCache)
    {
        CFRelease(_textureCache);
    }
    if (_soundFormat)
    {
        CFRelease(_soundFormat);
    }
}

#pragma mark State

- (BOOL)isRecording
{
    os_unfair_lock_lock(&_lock);
    BOOL recording = _recording;
    os_unfair_lock_unlock(&_lock);
    return recording;
}

- (NSUInteger)framesWritten
{
    os_unfair_lock_lock(&_lock);
    NSUInteger frames = _framesWritten;
    os_unfair_lock_unlock(&_lock);
    return frames;
}

- (NSUInteger)framesDropped
{
    os_unfair_lock_lock(&_lock);
    NSUInteger frames = _framesDropped;
    os_unfair_lock_unlock(&_lock);
    return frames;
}

- (NSUInteger)framesPending
{
    os_unfair_lock_lock(&_lock);
    NSUInteger frames = _framesPending;
    os_unfair_lock_unlock(&_lock);
    return frames;
}

- (NSTimeInterval)soundWritten
{
    os_unfair_lock_lock(&_lock);
    NSTimeInterval written = _soundWritten;
    os_unfair_lock_unlock(&_lock);
    return written;
}

- (NSTimeInterval)soundLeftOut
{
    os_unfair_lock_lock(&_lock);
    NSTimeInterval leftOut = _soundLeftOut;
    os_unfair_lock_unlock(&_lock);
    return leftOut;
}

- (NSSize)outputSize
{
    os_unfair_lock_lock(&_lock);
    NSSize size = _outputSize;
    os_unfair_lock_unlock(&_lock);
    return size;
}

#pragma mark Starting

- (BOOL)startWritingToURL:(NSURL *)url settings:(MovieRecorderSettings *)settings error:(NSError **)error
{
    return [self startWritingToURL:url settings:settings startTime:NAN error:error];
}

- (BOOL)startWritingToURL:(NSURL *)url
                 settings:(MovieRecorderSettings *)settings
                startTime:(NSTimeInterval)startTime
                    error:(NSError **)error
{
    NSString *problem = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *folder = url.URLByDeletingLastPathComponent.path;
    BOOL isFolder = NO;
    os_unfair_lock_lock(&_lock);
    BOOL recording = _recording, finishing = _finishing;
    os_unfair_lock_unlock(&_lock);
    if (recording)
    {
        problem = @"A recording is already in progress";
    }
    else if (finishing)
    {
        problem = @"The previous movie is still being finished";
    }
    else if (![fileManager fileExistsAtPath:folder isDirectory:&isFolder] || !isFolder)
    {
        problem = [NSString stringWithFormat:@"The folder \u201C%@\u201D does not exist", folder];
    }
    else if (![fileManager isWritableFileAtPath:folder])
    {
        problem = [NSString stringWithFormat:@"The folder \u201C%@\u201D cannot be written to", folder];
    }
    else if ([fileManager fileExistsAtPath:url.path])
    {
        problem = [NSString stringWithFormat:@"\u201C%@\u201D already exists", url.lastPathComponent];
    }
    if (problem)
    {
        if (error)
        {
            *error = RecorderError(problem);
        }
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    _outputSize = NSZeroSize;
    os_unfair_lock_unlock(&_lock);

    __block NSError *writerError = nil;
    dispatch_sync(_queue, ^{
        self->_url = url;
        self->_settings = [settings copy];
        self->_writer = nil;
        self->_input = nil;
        self->_adaptor = nil;
        self->_lastTime = kCMTimeInvalid;
        [self forgetSound];
        // Creating the writer takes long enough for a few frames to arrive. When the movie's size is given we do
        // it now, rather than when the first frame arrives, so that the frames which follow it are not lost.
        if (settings.width > 0 && settings.height > 0)
        {
            writerError = [self createWriterForFrameOfWidth:settings.width height:settings.height];
        }
    });
    if (writerError)
    {
        if (error)
        {
            *error = writerError;
        }
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    _pacer = [[FramePacer alloc] initWithFramesPerSecond:settings.framesPerSecond origin:startTime];
    // The time which is 0 in the movie: given, or that of the first frame
    _hasFirstFrame = !isnan(startTime);
    _firstFrameTime = startTime;
    _framesWritten = 0;
    _framesDropped = 0;
    _framesPending = 0;
    _recordsSound = settings.recordsSound;
    [_waitingSound removeAllObjects];
    _soundWaiting = 0.0;
    _soundWritten = 0.0;
    _soundLeftOut = 0.0;
    _recording = YES;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

// The writer is created when the first frame arrives, as the movie may take its size. Returns an error if it fails.
- (NSError *)createWriterForFrameOfWidth:(NSUInteger)frameWidth height:(NSUInteger)frameHeight
{
    NSInteger width = _settings.width, height = _settings.height;
    if (width <= 0 || height <= 0)
    {
        width = frameWidth;
        height = frameHeight;
    }
    // Video encoders want even dimensions
    width = MAX(width - (width % 2), 2);
    height = MAX(height - (height % 2), 2);

    AVVideoCodecType codec;
    NSMutableDictionary *compression = nil;
    switch (_settings.codec)
    {
        case MovieCodecProRes422:
            codec = AVVideoCodecTypeAppleProRes422;
            break;
        case MovieCodecProRes4444:
            codec = AVVideoCodecTypeAppleProRes4444;
            break;
        case MovieCodecHEVC:
        case MovieCodecH264:
        default:
        {
            BOOL hevc = _settings.codec == MovieCodecHEVC;
            codec = hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264;
            double framesPerSecond = _settings.framesPerSecond > 0.0 ? _settings.framesPerSecond : kAssumedFramesPerSecond;
            double bitsPerSecond = _settings.megabitsPerSecond * 1000000.0;
            if (bitsPerSecond <= 0.0)
            {
                // Bits for each pixel of each frame which give a good picture
                bitsPerSecond = MAX(width * height * framesPerSecond * (hevc ? 0.06 : 0.1), 1000000.0);
            }
            compression = [@{
                AVVideoAverageBitRateKey: @(bitsPerSecond),
                AVVideoExpectedSourceFrameRateKey: @(framesPerSecond),
                // A key frame at least every two seconds, so the movie is easy to move around in
                AVVideoMaxKeyFrameIntervalDurationKey: @2.0,
                AVVideoAllowFrameReorderingKey: @NO
            } mutableCopy];
            break;
        }
    }

    NSMutableDictionary *outputSettings = [@{
        AVVideoCodecKey: codec,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoColorPropertiesKey: @{
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        }
    } mutableCopy];
    if (compression)
    {
        outputSettings[AVVideoCompressionPropertiesKey] = compression;
    }

    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:_url fileType:AVFileTypeQuickTimeMovie error:&error];
    if (writer == nil)
    {
        return error ?: RecorderError(@"The movie file could not be created");
    }
    if (![writer canApplyOutputSettings:outputSettings forMediaType:AVMediaTypeVideo])
    {
        return RecorderError([NSString stringWithFormat:@"A %@ movie of %ld \u00D7 %ld cannot be written",
                              [MovieRecorderSettings nameForCodec:_settings.codec], (long)width, (long)height]);
    }
    // Write the movie in fragments, so that it can be played up to the last one if we are interrupted
    writer.movieFragmentInterval = CMTimeMake(10, 1);

    AVAssetWriterInput *input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    input.expectsMediaDataInRealTime = YES;
    input.mediaTimeScale = kTimescale;

    NSDictionary *bufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:input
                                                                                         sourcePixelBufferAttributes:bufferAttributes];
    if (![writer canAddInput:input])
    {
        return RecorderError(@"The movie file could not be set up");
    }
    [writer addInput:input];

    // The sound track is made now, whatever the source sends: its format cannot change once the movie is begun
    AVAssetWriterInput *audioInput = nil;
    if (_settings.recordsSound)
    {
        audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:[self soundOutputSettings]];
        audioInput.expectsMediaDataInRealTime = YES;
        if (![writer canAddInput:audioInput])
        {
            return RecorderError(@"The movie's sound track could not be set up");
        }
        [writer addInput:audioInput];
    }

    if (![writer startWriting])
    {
        NSError *startError = writer.error ?: RecorderError(@"The movie file could not be written");
        [writer cancelWriting];
        return startError;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // The writer accepts sizes for which no picture can be allocated: find out now rather than at every frame
    CVPixelBufferRef probe = NULL;
    CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
    if (pool == NULL || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &probe) != kCVReturnSuccess)
    {
        [writer cancelWriting];
        return RecorderError([NSString stringWithFormat:@"A movie of %ld \u00D7 %ld cannot be written", (long)width, (long)height]);
    }
    CVPixelBufferRelease(probe);

    _writer = writer;
    _input = input;
    _adaptor = adaptor;
    _audioInput = audioInput;

    os_unfair_lock_lock(&_lock);
    _outputSize = NSMakeSize(width, height);
    os_unfair_lock_unlock(&_lock);
    return nil;
}

- (NSDictionary *)soundOutputSettings
{
    AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo};
    NSData *layoutData = [NSData dataWithBytes:&layout length:sizeof(layout)];
    if (_settings.codec == MovieCodecProRes422 || _settings.codec == MovieCodecProRes4444)
    {
        return @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(kSoundRate),
            AVNumberOfChannelsKey: @2,
            AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: @24,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO
        };
    }
    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @(kSoundRate),
        AVNumberOfChannelsKey: @2,
        AVChannelLayoutKey: layoutData,
        AVEncoderBitRateKey: @256000
    };
}

#pragma mark Frames

- (void)appendTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped atTime:(NSTimeInterval)time
{
    os_unfair_lock_lock(&_lock);
    if (!_recording)
    {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    FramePacerDecision decision = [_pacer decisionForFrameAtTime:time];
    if (!decision.keep)
    {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    if (!_hasFirstFrame)
    {
        _hasFirstFrame = YES;
        _firstFrameTime = time;
    }
    if (_framesPending >= kMaximumFramesPending)
    {
        _framesDropped++;
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _framesPending++;
    os_unfair_lock_unlock(&_lock);

    dispatch_group_enter(_framesInFlight);
    dispatch_async(_queue, ^{
        [self drawTexture:texture flipped:flipped forTime:CMTimeMakeWithSeconds(decision.time, kTimescale)];
    });
}

- (BOOL)wantsFrameAtTime:(NSTimeInterval)time
{
    os_unfair_lock_lock(&_lock);
    BOOL wants = _recording && [_pacer wouldKeepFrameAtTime:time];
    if (wants && _framesPending >= kMaximumFramesPending)
    {
        // It would be dropped on arrival: it is dropped here, before it is made
        _framesDropped++;
        wants = NO;
    }
    os_unfair_lock_unlock(&_lock);
    return wants;
}

// A frame leaves the recorder, written or not
- (void)frameDoneWritten:(BOOL)written
{
    os_unfair_lock_lock(&_lock);
    _framesPending--;
    if (written)
    {
        _framesWritten++;
    }
    else
    {
        _framesDropped++;
    }
    os_unfair_lock_unlock(&_lock);
    dispatch_group_leave(_framesInFlight);
}

- (void)drawTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped forTime:(CMTime)time
{
    if (_writer == nil)
    {
        if (!self.recording)
        {
            // A previous frame failed
            [self frameDoneWritten:NO];
            return;
        }
        NSError *error = [self createWriterForFrameOfWidth:texture.width height:texture.height];
        if (error)
        {
            [self frameDoneWritten:NO];
            [self failWithError:error];
            return;
        }
    }

    if (_writer.status == AVAssetWriterStatusFailed)
    {
        // A full disk, for instance. Say so now: a failed writer has no pictures to give either, and that
        // would be reported instead.
        [self frameDoneWritten:NO];
        [self failWithError:_writer.error ?: RecorderError(@"The movie could not be written")];
        return;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVMetalTextureRef target = NULL;
    CVPixelBufferPoolRef pool = _adaptor.pixelBufferPool;
    if (pool)
    {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer);
    }
    if (pixelBuffer)
    {
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, pixelBuffer, NULL, MTLPixelFormatBGRA8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &target);
    }
    id<MTLTexture> targetTexture = target ? CVMetalTextureGetTexture(target) : nil;
    if (targetTexture == nil)
    {
        if (target) CFRelease(target);
        if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
        // Memory is short: this frame is lost. The movie goes on, as ending it here would lose what follows too.
        [self frameDoneWritten:NO];
        return;
    }

    // Scale to fit, with bars which are transparent if the movie keeps transparency
    BOOL keepsAlpha = _settings.codec == MovieCodecProRes4444;
    float ratio = MIN((float)targetTexture.width / texture.width, (float)targetTexture.height / texture.height);
    float width = texture.width * ratio / targetTexture.width;
    float height = texture.height * ratio / targetTexture.height;
    float top = flipped ? 1.0 : 0.0;
    float bottom = 1.0 - top;
    // x, y, u, v
    const float vertices[] = {
        -width, -height, 0.0, bottom,
        -width,  height, 0.0, top,
         width, -height, 1.0, bottom,
         width,  height, 1.0, top
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = targetTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, keepsAlpha ? 0.0 : 1.0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    dispatch_queue_t queue = _queue;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        BOOL drawn = buffer.status == MTLCommandBufferStatusCompleted;
        dispatch_async(queue, ^{
            [self appendPixelBuffer:(drawn ? pixelBuffer : NULL) atTime:time];
            CFRelease(target);
            CVPixelBufferRelease(pixelBuffer);
        });
    }];
    [commandBuffer commit];
}

- (void)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)time
{
    BOOL written = NO;
    // Times must increase: a frame which was overtaken is not written
    BOOL inOrder = !CMTIME_IS_VALID(_lastTime) || CMTimeCompare(time, _lastTime) > 0;
    BOOL writing = pixelBuffer && inOrder && _writer.status == AVAssetWriterStatusWriting;
    // Give the encoder a moment if it is busy. Frames which arrive meanwhile wait behind this one, and beyond
    // kMaximumFramesPending they are dropped as they arrive, so a slow encoder costs frames but never memory.
    // The writer may be waiting for sound to go with the pictures: the sound which waits is given meanwhile.
    for (int waited = 0; writing && !_input.readyForMoreMediaData && waited < kEncoderWaitMilliseconds; waited++)
    {
        [self writeWaitingSound];
        usleep(1000);
        writing = _writer.status == AVAssetWriterStatusWriting;
    }
    if (writing && _input.readyForMoreMediaData)
    {
        written = [_adaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
        if (written)
        {
            _lastTime = time;
        }
    }
    [self frameDoneWritten:written];
    // The encoder may take sound again now that it has this picture, and the movie's time 0 may just be known
    [self writeWaitingSound];

    if (_writer.status == AVAssetWriterStatusFailed && self.recording)
    {
        [self failWithError:_writer.error ?: RecorderError(@"The movie could not be written")];
    }
}

// On the recorder's queue. Stops the recording and tells our owner.
- (void)failWithError:(NSError *)error
{
    os_unfair_lock_lock(&_lock);
    BOOL wasRecording = _recording;
    _recording = NO;
    if (wasRecording)
    {
        _finishing = YES;
    }
    os_unfair_lock_unlock(&_lock);
    if (!wasRecording)
    {
        return;
    }
    // Cancelling deletes the file: only if nothing was written to it. A writer which failed keeps its file,
    // which can be played up to its last fragment.
    if (!CMTIME_IS_VALID(_lastTime))
    {
        [_writer cancelWriting];
    }
    _writer = nil;
    _input = nil;
    _adaptor = nil;
    [self forgetSound];
    // Frames still on their way belong to this recording: another can start once they have left
    dispatch_group_notify(_framesInFlight, _queue, ^{
        os_unfair_lock_lock(&self->_lock);
        self->_finishing = NO;
        os_unfair_lock_unlock(&self->_lock);
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.failureHandler)
        {
            self.failureHandler(error);
        }
    });
}

#pragma mark Sound

- (void)appendSound:(SourceSound *)sound atTime:(NSTimeInterval)time
{
    // The bound is on sound: silence owed is only a count, but the sound which waits behind a gap may wait longer,
    // until it is back under the usual bound. (A millionth of a second for the sums of durations.)
    os_unfair_lock_lock(&_lock);
    BOOL wanted = _recording && _recordsSound;
    NSTimeInterval maximum = _soundBehindGap ? kMaximumSoundWaitingBehindSilence : kMaximumSoundWaiting;
    os_unfair_lock_unlock(&_lock);
    if (!wanted)
    {
        return;
    }
    NSTimeInterval cutOff = 0.0;
    if (sound.duration > maximum + 1e-6)
    {
        // Longer than may wait: its last seconds are kept. It still arrived when its last sample was made. (Cut
        // here, as it copies, rather than while holding the lock which the frames take.)
        SourceSound *kept = [sound soundFromFrame:sound.frameCount - (NSUInteger)llround(maximum * sound.sampleRate)];
        cutOff = sound.duration - kept.duration;
        sound = kept;
    }
    WaitingSound *waiting = [[WaitingSound alloc] init];
    waiting.sound = sound;
    waiting.time = time;

    os_unfair_lock_lock(&_lock);
    if (!_recording || !_recordsSound)
    {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    [_waitingSound addObject:waiting];
    _soundWaiting += sound.duration;
    _soundLeftOut += cutOff;
    // The encoder is behind, or the movie is not made yet: the oldest sound is left out, and the timeline puts
    // silence in its place when sound is written again. The newest piece is always kept.
    maximum = (_soundBehindGap ? kMaximumSoundWaitingBehindSilence : kMaximumSoundWaiting) + 1e-6;
    while (_waitingSound.count > 1 && _soundWaiting > maximum)
    {
        NSTimeInterval duration = _waitingSound[0].sound.duration;
        [_waitingSound removeObjectAtIndex:0];
        _soundWaiting -= duration;
        _soundLeftOut += duration;
    }
    BOOL schedule = !_soundWriteScheduled;
    _soundWriteScheduled = YES;
    os_unfair_lock_unlock(&_lock);

    if (schedule)
    {
        [self scheduleSoundWrite];
    }
}

// The caller has set _soundWriteScheduled
- (void)scheduleSoundWrite
{
    [self scheduleSoundWriteAfter:0];
}

- (void)scheduleSoundWriteAfter:(int64_t)nanoseconds
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nanoseconds), _queue, ^{
        // Cleared first: sound which arrives from now on schedules another
        os_unfair_lock_lock(&self->_lock);
        self->_soundWriteScheduled = NO;
        os_unfair_lock_unlock(&self->_lock);
        [self writeWaitingSound];
    });
}

// On the recorder's queue. Gives the encoder the sound which waits, as much of it as it takes now. Never waits for
// the encoder, as pictures are written on this queue: it is called again after each picture, while a picture waits
// for the encoder, when sound arrives, and when the movie is finished.
- (void)writeWaitingSound
{
    if (_audioInput == nil || _writer.status != AVAssetWriterStatusWriting)
    {
        // No sound track, or not made yet: the sound waits
        return;
    }
    if (_soundTimeline == nil)
    {
        os_unfair_lock_lock(&_lock);
        BOOL known = _hasFirstFrame;
        NSTimeInterval origin = _firstFrameTime;
        os_unfair_lock_unlock(&_lock);
        if (!known)
        {
            // The movie's time 0 is that of its first frame, which has not come
            return;
        }
        _soundTimeline = [[SoundTimeline alloc] initWithOrigin:origin];
    }
    // Each call gives at most a second of silence, so that it takes little time whatever the gap
    int64_t silenceLeft = kLongestSilenceWritten;
    while (YES)
    {
        while (_placedSound.count > 0 && _audioInput.readyForMoreMediaData)
        {
            id placed = _placedSound[0];
            if ([placed isKindOfClass:[NSNumber class]])
            {
                int64_t owed = [placed longLongValue];
                if (owed <= 0)
                {
                    // Nothing is owed: it must not stop what follows
                    [_placedSound removeObjectAtIndex:0];
                    continue;
                }
                int64_t frames = MIN(owed, silenceLeft);
                if (frames == 0)
                {
                    // This call's silence is given
                    break;
                }
                if (![self appendSamples:NULL frameCount:(NSUInteger)frames])
                {
                    return;
                }
                silenceLeft -= frames;
                if (owed > frames)
                {
                    _placedSound[0] = @(owed - frames);
                }
                else
                {
                    [_placedSound removeObjectAtIndex:0];
                }
            }
            else
            {
                SourceSound *sound = placed;
                if (![self appendSamples:sound.samples frameCount:sound.frameCount])
                {
                    // The writer failed: the pictures report it
                    return;
                }
                [_placedSound removeObjectAtIndex:0];
            }
        }
        if ([self placedSoundIncludesSound])
        {
            // It waits for the encoder, or behind silence still owed, and what follows waits in the list
            break;
        }
        // Sound is placed even while silence is owed: placing costs little, and the sound which comes back after a
        // gap must not wait in the list, where it would be left out, while the silence is written
        os_unfair_lock_lock(&_lock);
        WaitingSound *next = _waitingSound.firstObject;
        if (next)
        {
            [_waitingSound removeObjectAtIndex:0];
            _soundWaiting -= next.sound.duration;
        }
        os_unfair_lock_unlock(&_lock);
        if (next == nil)
        {
            break;
        }
        [self placeSound:next.sound arrivedAtTime:next.time];
    }

    BOOL owed = NO;
    for (id placed in _placedSound)
    {
        owed = owed || [placed isKindOfClass:[NSNumber class]];
    }
    os_unfair_lock_lock(&_lock);
    _soundBehindGap = owed || (_soundBehindGap && _soundWaiting > kMaximumSoundWaiting + 1e-6);
    BOOL pending = _placedSound.count > 0 || _waitingSound.count > 0;
    BOOL schedule = pending && !_soundWriteScheduled;
    _soundWriteScheduled = _soundWriteScheduled || pending;
    os_unfair_lock_unlock(&_lock);
    if (schedule)
    {
        // The rest is given in later calls, with pictures between them, whether or not more sound or pictures come:
        // at once if the encoder takes more (silence is given a second at a time), a moment later if it is busy
        [self scheduleSoundWriteAfter:_audioInput.readyForMoreMediaData ? 0 : 2 * NSEC_PER_MSEC];
    }
}

- (BOOL)placedSoundIncludesSound
{
    for (id placed in _placedSound)
    {
        if ([placed isKindOfClass:[SourceSound class]])
        {
            return YES;
        }
    }
    return NO;
}

// On the recorder's queue. Puts a piece on the movie's clock, at 48 kHz, among the sound placed.
- (void)placeSound:(SourceSound *)sound arrivedAtTime:(NSTimeInterval)time
{
    NSTimeInterval silenceBefore = _soundTimeline.silenceAdded;
    NSArray<SourceSound *> *pieces = [_soundTimeline piecesForSound:sound arrivedAtTime:time];
    if (pieces.count == 0)
    {
        // Before the movie, early, or at a time which is wrong: nothing changes
        return;
    }
    // At 48 kHz: a silence of less than half a sample (one sample of a source above 96 kHz) is none
    int64_t silence = llround((_soundTimeline.silenceAdded - silenceBefore) * kSoundRate);
    if (sound.sampleRate != _soundRate || silence > 0)
    {
        // What the converter holds back goes before the silence, or ends the run of the last rate
        [self endConversion];
    }
    _soundRate = sound.sampleRate;
    if (_converter == nil && _soundRate != kSoundRate)
    {
        // The encoder converts only from the first rate it is given: we convert, so that a source which changes
        // rate keeps its pitch
        AVAudioFormat *from = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:_soundRate channels:2 interleaved:YES];
        AVAudioFormat *to = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kSoundRate channels:2 interleaved:YES];
        _converter = [[AVAudioConverter alloc] initFromFormat:from toFormat:to];
    }
    if (silence > 0)
    {
        // The timeline gives silence then the piece: the silence is owed as a count, made only as it is written
        [_placedSound addObject:@(silence)];
    }
    SourceSound *placed = _converter ? [self convertSound:pieces.lastObject] : pieces.lastObject;
    if (placed)
    {
        [_placedSound addObject:placed];
    }
}

// On the recorder's queue. What the converter holds back of the sound so far is placed, and it is let go.
- (void)endConversion
{
    if (_converter)
    {
        SourceSound *rest = [self convertSound:nil];
        if (rest)
        {
            [_placedSound addObject:rest];
        }
        _converter = nil;
    }
}

// A piece at 48 kHz, or for nil the end of the run. The converter keeps the timing (its prime method is "normal"),
// holding back its last few samples until the end of the run. nil if nothing comes out.
- (nullable SourceSound *)convertSound:(nullable SourceSound *)sound
{
    AVAudioPCMBuffer *input = nil;
    if (sound)
    {
        input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_converter.inputFormat frameCapacity:(AVAudioFrameCount)sound.frameCount];
        input.frameLength = (AVAudioFrameCount)sound.frameCount;
        memcpy(input.floatChannelData[0], sound.samples, sound.frameCount * 2 * sizeof(float));
    }
    AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(sound.frameCount * kSoundRate / _soundRate) + 1024;
    NSMutableData *samples = [NSMutableData data];
    __block BOOL given = NO;
    AVAudioConverterOutputStatus status;
    do
    {
        AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_converter.outputFormat frameCapacity:capacity];
        NSError *error = nil;
        status = [_converter convertToBuffer:output error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *inputStatus) {
            if (input == nil)
            {
                *inputStatus = AVAudioConverterInputStatus_EndOfStream;
                return nil;
            }
            if (given)
            {
                *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }
            given = YES;
            *inputStatus = AVAudioConverterInputStatus_HaveData;
            return input;
        }];
        if (status == AVAudioConverterOutputStatus_Error)
        {
            NSLog(@"MovieRecorder could not convert sound: %@", error);
            break;
        }
        [samples appendBytes:output.floatChannelData[0] length:output.frameLength * 2 * sizeof(float)];
    }
    while (status == AVAudioConverterOutputStatus_HaveData);
    return [SourceSound soundWithInterleavedStereoSamples:samples.bytes frameCount:samples.length / (2 * sizeof(float)) sampleRate:kSoundRate];
}

// On the recorder's queue. Samples at 48 kHz, or silence for NULL. NO if the encoder refused them.
- (BOOL)appendSamples:(nullable const float *)samples frameCount:(NSUInteger)frameCount
{
    size_t length = frameCount * 2 * sizeof(float);
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length, kCFAllocatorDefault, NULL, 0, length,
                                                         kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status == noErr)
    {
        status = samples ? CMBlockBufferReplaceDataBytes(samples, block, 0, length) : CMBlockBufferFillDataBytes(0, block, 0, length);
    }
    if (status == noErr)
    {
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, _soundFormat, (CMItemCount)frameCount,
                                                                      CMTimeMake(_soundPosition, (int32_t)kSoundRate), NULL, &sample);
    }
    BOOL appended = status == noErr && [_audioInput appendSampleBuffer:sample];
    if (sample) CFRelease(sample);
    if (block) CFRelease(block);
    if (appended)
    {
        _soundPosition += frameCount;
        os_unfair_lock_lock(&_lock);
        _soundWritten += frameCount / kSoundRate;
        os_unfair_lock_unlock(&_lock);
    }
    return appended;
}

// On the recorder's queue, when the movie is finished: the sound which waits is written, the encoder given a
// moment to take it. What it does not take in time is left out.
- (void)writeLastSound
{
    if (_audioInput == nil)
    {
        return;
    }
    BOOL ended = NO;
    int waited = 0;
    while (_writer.status == AVAssetWriterStatusWriting)
    {
        int64_t position = _soundPosition;
        [self writeWaitingSound];
        os_unfair_lock_lock(&_lock);
        BOOL waiting = _waitingSound.count > 0;
        os_unfair_lock_unlock(&_lock);
        if (!waiting && !ended && _soundTimeline)
        {
            [self endConversion];
            ended = YES;
            [self writeWaitingSound];
        }
        if (!waiting && _placedSound.count == 0)
        {
            return;
        }
        if (_soundPosition != position)
        {
            // The encoder took some (silence owed is given a second at a time): no need to wait
            waited = 0;
            continue;
        }
        if (waited++ >= kSoundFinishWaitMilliseconds)
        {
            break;
        }
        usleep(1000);
    }
    // Only sound counts as left out: silence still owed is not
    NSTimeInterval leftOut = 0.0;
    for (id placed in _placedSound)
    {
        if ([placed isKindOfClass:[SourceSound class]])
        {
            leftOut += ((SourceSound *)placed).duration;
        }
    }
    os_unfair_lock_lock(&_lock);
    _soundLeftOut += leftOut + _soundWaiting;
    os_unfair_lock_unlock(&_lock);
}

// On the recorder's queue: the sound of the movie which ends is forgotten
- (void)forgetSound
{
    _audioInput = nil;
    _soundTimeline = nil;
    _soundRate = 0.0;
    _converter = nil;
    [_placedSound removeAllObjects];
    _soundPosition = 0;
    os_unfair_lock_lock(&_lock);
    [_waitingSound removeAllObjects];
    _soundWaiting = 0.0;
    _soundBehindGap = NO;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark Finishing

- (void)finishAtTime:(NSTimeInterval)time completionHandler:(void (^)(NSError * _Nullable error))handler
{
    os_unfair_lock_lock(&_lock);
    BOOL wasRecording = _recording;
    _recording = NO;
    if (wasRecording)
    {
        _finishing = YES;
    }
    NSTimeInterval elapsed = _hasFirstFrame ? time - _firstFrameTime : 0.0;
    os_unfair_lock_unlock(&_lock);

    if (!wasRecording)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(RecorderError(@"There is no recording in progress"));
        });
        return;
    }

    // The recorder can be used again, and our owner is told
    void (^finished)(NSError *) = ^(NSError *error) {
        os_unfair_lock_lock(&self->_lock);
        self->_finishing = NO;
        os_unfair_lock_unlock(&self->_lock);
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(error);
        });
    };

    dispatch_group_notify(_framesInFlight, _queue, ^{
        AVAssetWriter *writer = self->_writer;
        AVAssetWriterInput *input = self->_input;
        AVAssetWriterInput *audioInput = self->_audioInput;
        BOOL hasFrames = writer != nil && CMTIME_IS_VALID(self->_lastTime);
        if (hasFrames)
        {
            [self writeLastSound];
        }
        [self forgetSound];
        self->_writer = nil;
        self->_input = nil;
        self->_adaptor = nil;

        // Sound alone is not a movie: it has no file. (Its writer has no frame, so cancelling loses nothing.)
        if (!hasFrames)
        {
            [writer cancelWriting];
            finished(RecorderError(@"No frame was received, so no movie was written"));
            return;
        }

        // The last frame stays on screen until the recording was stopped
        CMTime end = CMTimeMakeWithSeconds(elapsed, kTimescale);
        CMTime minimum = CMTimeAdd(self->_lastTime, CMTimeMake(kTimescale / 240, kTimescale));
        [input markAsFinished];
        [audioInput markAsFinished];
        [writer endSessionAtSourceTime:CMTimeMaximum(end, minimum)];
        [writer finishWritingWithCompletionHandler:^{
            finished(writer.status == AVAssetWriterStatusCompleted ? nil : (writer.error ?: RecorderError(@"The movie could not be finished")));
        }];
    });
}

@end
