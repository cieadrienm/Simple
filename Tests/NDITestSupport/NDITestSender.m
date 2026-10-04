/*
 NDITestSender.m
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

#import "NDITestSender.h"
#import "NDILibrary+Functions.h"
#import <QuartzCore/QuartzCore.h>

@implementation NDITestSender {
    NDILibrary *_library;
    NDIlib_send_instance_t _sender;
    NSString *_name;
    NSCondition *_condition;    // guards everything below
    NSMutableData *_picture;
    NSMutableData *_white;      // the picture all white, if it is marked
    NDIlib_video_frame_v2_t _frame;
    BOOL _threadRunning;
    BOOL _stopping;
    // Sound
    int _soundChannels;
    int _soundRate;
    double _toneFrequency;      // 0: silence with clicks
    int64_t _soundSample;       // the first sample of the next piece, for the tone's phase
    BOOL _clickPending;
    BOOL _whitePending;
    CFTimeInterval _clickSoundTime; // when the click's piece and white picture were handed to NDI, 0 until they are
    CFTimeInterval _clickPictureTime;
    BOOL _soundThreadRunning;
    BOOL _soundStopping;
}

- (instancetype)initWithLibrary:(NDILibrary *)library name:(NSString *)name
{
    const NDIlib_v5 *ndi = library.functions;
    if (!ndi)
        return nil;
    self = [super init];
    if (self) {
        NDIlib_send_create_t create = {0};
        create.p_ndi_name = name.UTF8String;
        create.clock_video = true;  // send_send_video_v2 then keeps the rate of the frames
        create.clock_audio = true;  // and send_send_audio_v3 that of the sound: each is sent from its own thread
        _sender = ndi->send_create(&create);
        if (!_sender)
            return nil;
        _library = library;
        _name = [name copy];
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (NSString *)sourceName
{
    [_condition lock];
    const NDIlib_source_t *source = _sender ? _library.functions->send_get_source_name(_sender) : NULL;
    NSString *name = source && source->p_ndi_name ? @(source->p_ndi_name) : _name;
    [_condition unlock];
    return name;
}

- (NSString *)sourceURL
{
    [_condition lock];
    const NDIlib_source_t *source = _sender ? _library.functions->send_get_source_name(_sender) : NULL;
    NSString *url = source && source->p_url_address ? @(source->p_url_address) : nil;
    [_condition unlock];
    return url;
}

- (void)sendWidth:(int)width height:(int)height colour:(const uint8_t *)bgra marked:(BOOL)marked
         hasAlpha:(BOOL)hasAlpha padding:(int)padding framesPerSecond:(int)framesPerSecond
{
    static const uint8_t orange[4] = {0, 165, 255, 255};
    int stride = width * 4 + padding;
    NSMutableData *picture = [NSMutableData dataWithLength:(NSUInteger)stride * (NSUInteger)height];
    uint8_t *bytes = picture.mutableBytes;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // NDI's first row is the top one
            const uint8_t *colour = marked && x < width / 2 && y < height / 2 ? orange : bgra;
            memcpy(bytes + (size_t)y * stride + (size_t)x * 4, colour, 4);
        }
    }

    NSMutableData *white = nil;
    if (marked) {
        white = [NSMutableData dataWithLength:picture.length];
        memset(white.mutableBytes, 255, white.length);
    }

    [_condition lock];
    if (!_sender || _stopping) {
        [_condition unlock];
        return;
    }
    _picture = picture;
    _white = white;
    _frame = (NDIlib_video_frame_v2_t){0};
    _frame.xres = width;
    _frame.yres = height;
    _frame.FourCC = hasAlpha ? NDIlib_FourCC_video_type_BGRA : NDIlib_FourCC_video_type_BGRX;
    _frame.frame_rate_N = framesPerSecond > 0 ? framesPerSecond : 30;
    _frame.frame_rate_D = 1;
    _frame.picture_aspect_ratio = (float)width / (float)height;
    _frame.frame_format_type = NDIlib_frame_format_type_progressive;
    _frame.timecode = NDIlib_send_timecode_synthesize;
    _frame.p_data = bytes;
    _frame.line_stride_in_bytes = stride;
    if (!_threadRunning) {
        _threadRunning = YES;
        NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        thread.name = @"NDITestSender";
        [thread start];
    }
    [_condition unlock];
}

- (void)run
{
    const NDIlib_v5 *ndi = _library.functions;
    for (;;) {
        [_condition lock];
        if (_stopping) {
            _threadRunning = NO;
            [_condition broadcast];
            [_condition unlock];
            return;
        }
        // The picture is kept alive by this reference while it is sent, even if a new one replaces it
        __attribute__((objc_precise_lifetime)) NSMutableData *picture = _picture;
        NDIlib_video_frame_v2_t frame = _frame;
        NDIlib_send_instance_t sender = _sender;
        if (_whitePending) {
            _whitePending = NO;
            if (_white) {
                picture = _white;
                frame.p_data = _white.mutableBytes;
                _clickPictureTime = CACurrentMediaTime();
                [self logClick];
            }
        }
        [_condition unlock];
        // Synchronous, and clocked: it returns when the frame is due
        ndi->send_send_video_v2(sender, &frame);
    }
}

// MARK: Sound

- (void)sendToneOfFrequency:(double)frequency channelCount:(int)channels sampleRate:(int)rate
{
    [self sendSoundOfFrequency:frequency channelCount:channels sampleRate:rate];
}

- (void)sendSilenceWithClicksOfChannelCount:(int)channels sampleRate:(int)rate
{
    [self sendSoundOfFrequency:0 channelCount:channels sampleRate:rate];
}

- (void)sendSoundOfFrequency:(double)frequency channelCount:(int)channels sampleRate:(int)rate
{
    [_condition lock];
    if (_sender && !_stopping && channels > 0 && rate >= 50) {
        _toneFrequency = frequency;
        _soundChannels = channels;
        _soundRate = rate;
        if (!_soundThreadRunning) {
            _soundThreadRunning = YES;
            NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(runSound) object:nil];
            thread.name = @"NDITestSender sound";
            [thread start];
        }
    }
    [_condition unlock];
}

- (void)click
{
    [_condition lock];
    _clickPending = YES;
    _whitePending = YES;
    _clickSoundTime = 0;
    _clickPictureTime = 0;
    [_condition unlock];
}

// Under the lock: once the click's sound and picture have both been handed to NDI
- (void)logClick
{
    if (_clickSoundTime > 0 && _clickPictureTime > 0) {
        NSLog(@"NDITestSender: a click's white picture was sent %+.1f ms after its sound",
              (_clickPictureTime - _clickSoundTime) * 1000);
        _clickSoundTime = 0;
        _clickPictureTime = 0;
    }
}

- (void)runSound
{
    const NDIlib_v5 *ndi = _library.functions;
    for (;;) {
        [_condition lock];
        if (_stopping || _soundStopping) {
            _soundThreadRunning = NO;
            [_condition broadcast];
            [_condition unlock];
            return;
        }
        int channels = _soundChannels;
        int rate = _soundRate;
        double frequency = _toneFrequency;
        int64_t first = _soundSample;
        int samples = rate / 50;
        _soundSample += samples;
        BOOL click = _clickPending;
        _clickPending = NO;
        NDIlib_send_instance_t sender = _sender;
        [_condition unlock];

        // Planar: each channel's samples follow the previous channel's
        NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)channels * (NSUInteger)samples * sizeof(float)];
        float *planes = buffer.mutableBytes;
        for (int channel = 0; channel < channels; channel++) {
            float *plane = planes + (size_t)channel * (size_t)samples;
            if (frequency > 0) {
                double step = 2 * M_PI * frequency * (channel + 1) / rate;
                for (int index = 0; index < samples; index++)
                    plane[index] = (float)(0.5 * sin(step * (double)(first + index)));
            } else if (click) {
                int pulse = MIN(MAX(rate / 200, 1), samples);
                for (int index = 0; index < pulse; index++)
                    plane[index] = 1;
            }
        }
        NDIlib_audio_frame_v3_t frame = {0};
        frame.sample_rate = rate;
        frame.no_channels = channels;
        frame.no_samples = samples;
        frame.timecode = NDIlib_send_timecode_synthesize;
        frame.FourCC = NDIlib_FourCC_audio_type_FLTP;
        frame.p_data = (uint8_t *)planes;
        frame.channel_stride_in_bytes = samples * (int)sizeof(float);
        if (click && frequency <= 0) {
            [_condition lock];
            _clickSoundTime = CACurrentMediaTime();
            [self logClick];
            [_condition unlock];
        }
        // Synchronous, and clocked: it keeps the rate of the sound
        ndi->send_send_audio_v3(sender, &frame);
    }
}

- (void)stopSound
{
    [_condition lock];
    _soundStopping = YES;
    while (_soundThreadRunning)
        [_condition wait];
    _soundStopping = NO;
    [_condition unlock];
}

- (void)stop
{
    [_condition lock];
    _stopping = YES;
    // The threads must be done with the sender before it is destroyed
    while (_threadRunning || _soundThreadRunning)
        [_condition wait];
    NDIlib_send_instance_t sender = _sender;
    _sender = NULL;
    _picture = nil;
    [_condition unlock];
    if (sender)
        _library.functions->send_destroy(sender);
}

// MARK: Receiving

static NSSize ReceiveOneFrame(const NDIlib_v5 *ndi, NDIlib_source_t source, NSDate *deadline)
{
    NDIlib_recv_create_v3_t create = {0};
    create.source_to_connect_to = source;
    create.color_format = NDIlib_recv_color_format_BGRX_BGRA;   // what was sent comes back
    create.bandwidth = NDIlib_recv_bandwidth_highest;
    create.allow_video_fields = false;
    create.p_ndi_recv_name = "Simple Recorder test";
    NDIlib_recv_instance_t receiver = ndi->recv_create_v3(&create);
    if (!receiver)
        return NSZeroSize;
    NSSize size = NSZeroSize;
    while (deadline.timeIntervalSinceNow > 0) {
        NDIlib_video_frame_v2_t video = {0};
        NDIlib_audio_frame_v3_t audio = {0};
        NDIlib_metadata_frame_t metadata = {0};
        NDIlib_frame_type_e type = ndi->recv_capture_v3(receiver, &video, &audio, &metadata, 500);
        if (type == NDIlib_frame_type_video) {
            size = NSMakeSize(video.xres, video.yres);
            ndi->recv_free_video_v2(receiver, &video);
            break;
        }
        if (type == NDIlib_frame_type_audio)
            ndi->recv_free_audio_v3(receiver, &audio);
        else if (type == NDIlib_frame_type_metadata)
            ndi->recv_free_metadata(receiver, &metadata);
    }
    ndi->recv_destroy(receiver);
    return size;
}

+ (NSSize)receiveOneFrameNamed:(NSString *)name library:(NDILibrary *)library timeout:(NSTimeInterval)timeout
{
    const NDIlib_v5 *ndi = library.functions;
    if (!ndi)
        return NSZeroSize;
    NSDate *start = [NSDate date];
    NSDate *deadline = [start dateByAddingTimeInterval:timeout];
    NDIlib_find_create_t create = {0};
    create.show_local_sources = true;
    NDIlib_find_instance_t find = ndi->find_create_v2(&create);
    if (!find)
        return NSZeroSize;
    // NDI names a source "HOST (name)"; only ours is looked at, never another application's
    NSString *suffix = [NSString stringWithFormat:@"(%@)", name];
    NSSize size = NSZeroSize;
    while (deadline.timeIntervalSinceNow > 0) {
        ndi->find_wait_for_sources(find, 500);
        uint32_t count = 0;
        const NDIlib_source_t *sources = ndi->find_get_current_sources(find, &count);
        const NDIlib_source_t *ours = NULL;
        for (uint32_t index = 0; index < count && !ours; index++) {
            if (sources[index].p_ndi_name && [@(sources[index].p_ndi_name) hasSuffix:suffix])
                ours = &sources[index];
        }
        if (ours) {
            NSLog(@"NDITestSender: found %s at %s after %.2f s", ours->p_ndi_name,
                  ours->p_url_address ?: "(no address)", -start.timeIntervalSinceNow);
            // The source's strings belong to the finder, which lives until the receiver is made
            size = ReceiveOneFrame(ndi, *ours, deadline);
            break;
        }
    }
    ndi->find_destroy(find);
    return size;
}

+ (NSSize)receiveOneFrameFromSource:(NSString *)sourceName url:(NSString *)url library:(NDILibrary *)library
                            timeout:(NSTimeInterval)timeout
{
    const NDIlib_v5 *ndi = library.functions;
    if (!ndi)
        return NSZeroSize;
    NDIlib_source_t source = {0};
    source.p_ndi_name = sourceName.UTF8String;
    source.p_url_address = url.length > 0 ? url.UTF8String : NULL;
    return ReceiveOneFrame(ndi, source, [NSDate dateWithTimeIntervalSinceNow:timeout]);
}

@end
