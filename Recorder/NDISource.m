/*
 NDISource.m
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

#import "NDISource.h"
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>
#import "NDILibrary+Functions.h"
#import "NDITextureRing.h"
#import "SourceSound.h"

// How long the thread waits for a frame before it looks at stop again: what stop may wait
static const uint32_t NDISourceCaptureMilliseconds = 100;
// A source just made is alive this long without being connected: a connection takes a moment
static const NSTimeInterval NDISourceConnectionGrace = 3.0;
// A source has sound until this long after its last piece
static const NSTimeInterval NDISourceSoundGrace = 3.0;

// What the source and its thread share: the thread holds this, not the source, so that releasing the source stops it
@interface NDISourceState : NSObject
@property (readonly) NSCondition *condition;    // guards receiver, stopping, running, thread, lastSoundTime
@property (assign) NDIlib_recv_instance_t receiver; // NULL once the thread is about to destroy it
@property BOOL stopping;
@property BOOL running;
@property (assign) pthread_t thread;
@property CFTimeInterval lastSoundTime;         // when the last piece of sound arrived, 0 if none has
@property (readonly) NSRecursiveLock *callLock; // guards stopped and the handlers, and is held while one runs
@property BOOL stopped;
@property (copy, nullable) void (^handler)(id<MTLTexture>);
@property (copy, nullable) void (^soundHandler)(SourceSound *);
// The strings the receiver was made from, NUL-terminated: NDI may read them for as long as the receiver lives
@property (readonly) NSData *name;
@property (readonly, nullable) NSData *url;
@end

// UTF8String is only valid as long as the string, maybe less: the bytes are copied, and kept
static NSData *NDISourceCString(NSString *string)
{
    NSMutableData *bytes = [[string dataUsingEncoding:NSUTF8StringEncoding] mutableCopy] ?: [NSMutableData data];
    [bytes appendBytes:"" length:1];
    return bytes;
}

@implementation NDISourceState
- (instancetype)initWithName:(NSString *)name url:(NSString *)url
{
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _callLock = [[NSRecursiveLock alloc] init];
        _name = NDISourceCString(name);
        _url = url.length > 0 ? NDISourceCString(url) : nil;
    }
    return self;
}
@end

@implementation NDISource {
    NDILibrary *_library;
    NDISourceState *_state;
    CFTimeInterval _madeTime;
}

@synthesize title = _title;

- (instancetype)initWithTitle:(NSString *)title name:(NSString *)name url:(NSString *)url library:(NDILibrary *)library
                       device:(id<MTLDevice>)device
{
    const NDIlib_v5 *ndi = library.functions;
    if (!ndi)
        return nil;
    self = [super init];
    if (self) {
        NDISourceState *state = [[NDISourceState alloc] initWithName:name url:url];
        NDIlib_recv_create_v3_t create = {0};
        create.source_to_connect_to.p_ndi_name = state.name.bytes;
        create.source_to_connect_to.p_url_address = state.url.bytes;
        create.color_format = NDIlib_recv_color_format_BGRX_BGRA;  // BGRA when there is alpha, BGRX when there is not
        create.bandwidth = NDIlib_recv_bandwidth_highest;
        create.allow_video_fields = false;
        create.p_ndi_recv_name = "SimpleRecorder";
        NDIlib_recv_instance_t receiver = ndi->recv_create_v3(&create);
        if (!receiver)
            return nil;
        _title = [title copy];
        _library = library;
        _madeTime = CACurrentMediaTime();
        _state = state;
        state.receiver = receiver;
        state.running = YES;
        NDITextureRing *ring = [[NDITextureRing alloc] initWithDevice:device];
        NSString *sourceTitle = _title;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            NDISourceRun(ndi, receiver, state, ring, sourceTitle);
        }];
        thread.name = @"NDISource";
        thread.qualityOfService = NSQualityOfServiceUserInteractive;
        [thread start];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

static void NDISourceRun(const NDIlib_v5 *ndi, NDIlib_recv_instance_t receiver, NDISourceState *state,
                         NDITextureRing *ring, NSString *title)
{
    [state.condition lock];
    state.thread = pthread_self();
    [state.condition unlock];
    BOOL toldFourCC = NO;
    BOOL toldSoundFourCC = NO;
    for (;;) {
        @autoreleasepool {
            [state.condition lock];
            BOOL stopping = state.stopping;
            [state.condition unlock];
            if (stopping)
                break;
            NDIlib_video_frame_v2_t video = {0};
            NDIlib_audio_frame_v3_t audio = {0};
            // No metadata frame is asked for
            switch (ndi->recv_capture_v3(receiver, &video, &audio, NULL, NDISourceCaptureMilliseconds)) {
                case NDIlib_frame_type_video:
                    NDISourceDeliver(&video, state, ring, title, &toldFourCC);
                    ndi->recv_free_video_v2(receiver, &video);
                    break;
                case NDIlib_frame_type_audio:
                    NDISourceDeliverSound(&audio, state, title, &toldSoundFourCC);
                    ndi->recv_free_audio_v3(receiver, &audio);
                    break;
                default:
                    // Nothing came, the source changed, or the connection was lost: the SDK connects again by itself
                    break;
            }
        }
    }
    // Taken away first, under the lock, so that alive no longer asks it
    [state.condition lock];
    state.receiver = NULL;
    [state.condition unlock];
    ndi->recv_destroy(receiver);
    [state.condition lock];
    state.running = NO;
    [state.condition broadcast];
    [state.condition unlock];
}

static void NDISourceDeliver(const NDIlib_video_frame_v2_t *video, NDISourceState *state, NDITextureRing *ring,
                             NSString *title, BOOL *toldFourCC)
{
    BOOL hasAlpha;
    if (video->FourCC == NDIlib_FourCC_video_type_BGRA) {
        hasAlpha = YES;
    } else if (video->FourCC == NDIlib_FourCC_video_type_BGRX) {
        hasAlpha = NO;
    } else {
        // The receiver asks for BGRX or BGRA: anything else is not expected, and is dropped
        if (!*toldFourCC) {
            uint32_t fourCC = (uint32_t)video->FourCC;
            NSLog(@"NDISource: %@ sends pictures as %.4s, which are dropped", title, (const char *)&fourCC);
            *toldFourCC = YES;
        }
        return;
    }
    if (video->xres <= 0 || video->yres <= 0 || video->line_stride_in_bytes <= 0 || !video->p_data)
        return;
    id<MTLTexture> texture = [ring textureWithBytes:video->p_data
                                              width:(NSUInteger)video->xres
                                             height:(NSUInteger)video->yres
                                        bytesPerRow:(NSUInteger)video->line_stride_in_bytes
                                           hasAlpha:hasAlpha];
    if (!texture)
        return;
    [state.callLock lock];
    void (^handler)(id<MTLTexture>) = state.stopped ? nil : state.handler;
    if (handler)
        handler(texture);
    [state.callLock unlock];
}

static void NDISourceDeliverSound(const NDIlib_audio_frame_v3_t *audio, NDISourceState *state, NSString *title,
                                  BOOL *toldFourCC)
{
    if (audio->FourCC != NDIlib_FourCC_audio_type_FLTP) {
        // What the receiver gives unless asked otherwise: anything else is not expected, and is left out
        if (!*toldFourCC) {
            uint32_t fourCC = (uint32_t)audio->FourCC;
            NSLog(@"NDISource: %@ sends sound as %.4s, which is left out", title, (const char *)&fourCC);
            *toldFourCC = YES;
        }
        return;
    }
    if (audio->no_channels <= 0 || audio->no_samples <= 0 || audio->channel_stride_in_bytes <= 0 || audio->sample_rate <= 0
        || !audio->p_data)
        return;
    SourceSound *sound = [SourceSound soundWithPlanarSamples:(const float *)audio->p_data
                                                channelCount:(NSUInteger)audio->no_channels
                                                  frameCount:(NSUInteger)audio->no_samples
                                        channelStrideInBytes:(NSUInteger)audio->channel_stride_in_bytes
                                                  sampleRate:audio->sample_rate];
    if (!sound)
        return;
    [state.condition lock];
    state.lastSoundTime = CACurrentMediaTime();
    [state.condition unlock];
    [state.callLock lock];
    void (^handler)(SourceSound *) = state.stopped ? nil : state.soundHandler;
    if (handler)
        handler(sound);
    [state.callLock unlock];
}

- (BOOL)flipped
{
    // NDI's first row is the top one
    return NO;
}

- (FrameSourceKind)kind
{
    return FrameSourceKindNDI;
}

- (void (^)(id<MTLTexture>))frameHandler
{
    [_state.callLock lock];
    void (^handler)(id<MTLTexture>) = _state.handler;
    [_state.callLock unlock];
    return handler;
}

- (void)setFrameHandler:(void (^)(id<MTLTexture>))frameHandler
{
    [_state.callLock lock];
    if (!_state.stopped)
        _state.handler = frameHandler;
    [_state.callLock unlock];
}

- (void (^)(SourceSound *))soundHandler
{
    [_state.callLock lock];
    void (^handler)(SourceSound *) = _state.soundHandler;
    [_state.callLock unlock];
    return handler;
}

- (void)setSoundHandler:(void (^)(SourceSound *))soundHandler
{
    [_state.callLock lock];
    if (!_state.stopped)
        _state.soundHandler = soundHandler;
    [_state.callLock unlock];
}

- (BOOL)hasSound
{
    // Written by the thread as each piece arrives; a source which stops has no more sound three seconds later
    [_state.condition lock];
    CFTimeInterval last = _state.lastSoundTime;
    [_state.condition unlock];
    return last > 0 && CACurrentMediaTime() - last < NDISourceSoundGrace;
}

- (BOOL)isAlive
{
    // The SDK's receiver is made to be used from several threads at once (its captures may run on several), so it can
    // be asked how many connections it has while the thread captures from it. What it must not be is asked once
    // destroyed: the thread takes it away under this lock before destroying it.
    BOOL alive = NO;
    [_state.condition lock];
    NDIlib_recv_instance_t receiver = _state.receiver;
    if (receiver && !_state.stopping)
        alive = CACurrentMediaTime() - _madeTime < NDISourceConnectionGrace
            || _library.functions->recv_get_no_connections(receiver) > 0;
    [_state.condition unlock];
    return alive;
}

- (void)stop
{
    // Waits for a handler which is running, so that none runs once this returns
    [_state.callLock lock];
    _state.stopped = YES;
    _state.handler = nil;
    _state.soundHandler = nil;
    [_state.callLock unlock];

    [_state.condition lock];
    _state.stopping = YES;
    // The thread destroys the receiver as it ends. Here on the thread itself (its handler let go of the source last), it
    // cannot be waited for: it ends once this returns.
    if (!pthread_equal(_state.thread, pthread_self())) {
        while (_state.running)
            [_state.condition wait];
    }
    [_state.condition unlock];
}

@end
