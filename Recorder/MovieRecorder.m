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
        if (_pipeline == nil || _textureCache == NULL)
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

    os_unfair_lock_lock(&_lock);
    _outputSize = NSMakeSize(width, height);
    os_unfair_lock_unlock(&_lock);
    return nil;
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
    for (int waited = 0; writing && !_input.readyForMoreMediaData && waited < kEncoderWaitMilliseconds; waited++)
    {
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
        self->_writer = nil;
        self->_input = nil;
        self->_adaptor = nil;

        if (writer == nil || !CMTIME_IS_VALID(self->_lastTime))
        {
            [writer cancelWriting];
            finished(RecorderError(@"No frame was received, so no movie was written"));
            return;
        }

        // The last frame stays on screen until the recording was stopped
        CMTime end = CMTimeMakeWithSeconds(elapsed, kTimescale);
        CMTime minimum = CMTimeAdd(self->_lastTime, CMTimeMake(kTimescale / 240, kTimescale));
        [input markAsFinished];
        [writer endSessionAtSourceTime:CMTimeMaximum(end, minimum)];
        [writer finishWritingWithCompletionHandler:^{
            finished(writer.status == AVAssetWriterStatusCompleted ? nil : (writer.error ?: RecorderError(@"The movie could not be finished")));
        }];
    });
}

@end
