/*
 ComputerSound.m
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

#import "ComputerSound.h"
#import "SourceSound.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <os/lock.h>

@implementation ComputerSound {
    os_unfair_lock _lock;
    void (^_soundHandler)(SourceSound *sound);
    BOOL _active;
    BOOL _heardSound;
    dispatch_queue_t _queue;
    AudioObjectID _tapID;
    AudioObjectID _aggregateDeviceID;
    AudioDeviceIOProcID _ioProcID;
    BOOL _running;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _lock = OS_UNFAIR_LOCK_INIT;
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _queue = dispatch_queue_create("net.am-cb.simple.computer-sound", attr);
        _tapID = kAudioObjectUnknown;
        _aggregateDeviceID = kAudioObjectUnknown;
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (void (^)(SourceSound *))soundHandler
{
    os_unfair_lock_lock(&_lock);
    void (^handler)(SourceSound *) = _soundHandler;
    os_unfair_lock_unlock(&_lock);
    return handler;
}

- (void)setSoundHandler:(void (^)(SourceSound *))soundHandler
{
    os_unfair_lock_lock(&_lock);
    _soundHandler = [soundHandler copy];
    os_unfair_lock_unlock(&_lock);
}

+ (nullable SourceSound *)soundFromBufferList:(const AudioBufferList *)bufferList
                                       format:(AudioStreamBasicDescription)format
                               ignoreIfSilent:(BOOL)ignoreIfSilent
{
    if (bufferList == NULL || bufferList->mNumberBuffers == 0)
    {
        return nil;
    }
    if (format.mFormatID != kAudioFormatLinearPCM
        || (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0
        || (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        || format.mBitsPerChannel != 32
        || !isfinite(format.mSampleRate) || format.mSampleRate <= 0.0)
    {
        return nil;
    }

    BOOL nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 || bufferList->mNumberBuffers > 1;
    if (nonInterleaved)
    {
        const AudioBuffer *first = &bufferList->mBuffers[0];
        if (first->mData == NULL || first->mDataByteSize < sizeof(float))
        {
            return nil;
        }
        NSUInteger frameCount = first->mDataByteSize / sizeof(float);
        const float *left = (const float *)first->mData;
        const float *right = left;
        if (bufferList->mNumberBuffers > 1)
        {
            const AudioBuffer *second = &bufferList->mBuffers[1];
            if (second->mData == NULL || second->mDataByteSize < frameCount * sizeof(float))
            {
                return nil;
            }
            right = (const float *)second->mData;
        }
        if (ignoreIfSilent)
        {
            BOOL hasSound = NO;
            for (NSUInteger i = 0; i < frameCount; i++)
            {
                if (left[i] != 0.0f || right[i] != 0.0f)
                {
                    hasSound = YES;
                    break;
                }
            }
            if (!hasSound)
            {
                return nil;
            }
        }
        float *stereo = malloc(frameCount * 2 * sizeof(float));
        if (stereo == NULL)
        {
            return nil;
        }
        for (NSUInteger i = 0; i < frameCount; i++)
        {
            stereo[i * 2] = left[i];
            stereo[i * 2 + 1] = right[i];
        }
        SourceSound *sound = [SourceSound soundWithInterleavedStereoSamples:stereo frameCount:frameCount sampleRate:format.mSampleRate];
        free(stereo);
        return sound;
    }

    const AudioBuffer *first = &bufferList->mBuffers[0];
    NSUInteger channels = first->mNumberChannels > 0 ? first->mNumberChannels : format.mChannelsPerFrame;
    if (channels == 0 || first->mData == NULL || first->mDataByteSize < channels * sizeof(float))
    {
        return nil;
    }
    NSUInteger frameCount = first->mDataByteSize / (channels * sizeof(float));
    const float *samples = (const float *)first->mData;
    if (ignoreIfSilent)
    {
        NSUInteger kept = MIN(channels, (NSUInteger)2);
        BOOL hasSound = NO;
        for (NSUInteger frame = 0; frame < frameCount && !hasSound; frame++)
        {
            for (NSUInteger ch = 0; ch < kept; ch++)
            {
                if (samples[frame * channels + ch] != 0.0f)
                {
                    hasSound = YES;
                    break;
                }
            }
        }
        if (!hasSound)
        {
            return nil;
        }
    }
    if (channels == 2)
    {
        return [SourceSound soundWithInterleavedStereoSamples:samples frameCount:frameCount sampleRate:format.mSampleRate];
    }
    if (channels == 1)
    {
        return [SourceSound soundWithPlanarSamples:samples channelCount:1 frameCount:frameCount channelStrideInBytes:0 sampleRate:format.mSampleRate];
    }
    float *stereo = malloc(frameCount * 2 * sizeof(float));
    if (stereo == NULL)
    {
        return nil;
    }
    for (NSUInteger frame = 0; frame < frameCount; frame++)
    {
        stereo[frame * 2] = samples[frame * channels];
        stereo[frame * 2 + 1] = samples[frame * channels + 1];
    }
    SourceSound *sound = [SourceSound soundWithInterleavedStereoSamples:stereo frameCount:frameCount sampleRate:format.mSampleRate];
    free(stereo);
    return sound;
}

- (BOOL)start
{
    if (_running)
    {
        return YES;
    }
    if (@available(macOS 14.2, *))
    {
        CATapDescription *tapDescription = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
        tapDescription.name = @"SimpleRecorder";
        tapDescription.UUID = [NSUUID UUID];
        tapDescription.privateTap = YES;
        tapDescription.muteBehavior = CATapUnmuted;

        AudioObjectID tapID = kAudioObjectUnknown;
        if (AudioHardwareCreateProcessTap(tapDescription, &tapID) != noErr || tapID == kAudioObjectUnknown)
        {
            return NO;
        }

        NSDictionary *description = @{
            @kAudioAggregateDeviceNameKey: @"SimpleRecorder",
            @kAudioAggregateDeviceUIDKey: [NSUUID UUID].UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceTapListKey: @[
                @{
                    @kAudioSubTapUIDKey: tapDescription.UUID.UUIDString,
                    @kAudioSubTapDriftCompensationKey: @YES
                }
            ]
        };
        AudioObjectID aggregateID = kAudioObjectUnknown;
        if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &aggregateID) != noErr
            || aggregateID == kAudioObjectUnknown)
        {
            AudioHardwareDestroyProcessTap(tapID);
            return NO;
        }

        AudioStreamBasicDescription format = {0};
        UInt32 size = sizeof(format);
        AudioObjectPropertyAddress streamAddress = {
            kAudioDevicePropertyStreamFormat,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        OSStatus status = AudioObjectGetPropertyData(aggregateID, &streamAddress, 0, NULL, &size, &format);
        if (status != noErr || format.mSampleRate <= 0.0)
        {
            size = sizeof(format);
            AudioObjectPropertyAddress tapAddress = {
                kAudioTapPropertyFormat,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            status = AudioObjectGetPropertyData(tapID, &tapAddress, 0, NULL, &size, &format);
        }
        if (status != noErr || format.mSampleRate <= 0.0)
        {
            AudioHardwareDestroyAggregateDevice(aggregateID);
            AudioHardwareDestroyProcessTap(tapID);
            return NO;
        }

        os_unfair_lock_lock(&_lock);
        _active = YES;
        _heardSound = NO;
        os_unfair_lock_unlock(&_lock);

        __weak ComputerSound *weakSelf = self;
        AudioDeviceIOProcID ioProcID = NULL;
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, _queue,
            ^(const AudioTimeStamp *inNow, const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
              AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime) {
            ComputerSound *strongSelf = weakSelf;
            if (strongSelf == nil)
            {
                return;
            }
            os_unfair_lock_lock(&strongSelf->_lock);
            BOOL active = strongSelf->_active;
            BOOL heard = strongSelf->_heardSound;
            void (^handler)(SourceSound *) = strongSelf->_soundHandler;
            os_unfair_lock_unlock(&strongSelf->_lock);
            if (!active || handler == nil)
            {
                return;
            }
            // Silent buffers before any sound has played (or when macOS has not granted permission yet) are left
            // out: a movie whose track never receives sound has no track at all (D69). Once sound has begun, every
            // buffer is given so that pauses stay in step.
            SourceSound *sound = [ComputerSound soundFromBufferList:inInputData format:format ignoreIfSilent:!heard];
            if (sound == nil)
            {
                return;
            }
            if (!heard)
            {
                os_unfair_lock_lock(&strongSelf->_lock);
                strongSelf->_heardSound = YES;
                os_unfair_lock_unlock(&strongSelf->_lock);
            }
            handler(sound);
        });
        if (status != noErr || ioProcID == NULL || AudioDeviceStart(aggregateID, ioProcID) != noErr)
        {
            os_unfair_lock_lock(&_lock);
            _active = NO;
            os_unfair_lock_unlock(&_lock);
            if (ioProcID)
            {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID);
            }
            AudioHardwareDestroyAggregateDevice(aggregateID);
            AudioHardwareDestroyProcessTap(tapID);
            return NO;
        }

        _tapID = tapID;
        _aggregateDeviceID = aggregateID;
        _ioProcID = ioProcID;
        _running = YES;
        return YES;
    }
    return NO;
}

- (void)stop
{
    if (!_running)
    {
        return;
    }
    _running = NO;
    os_unfair_lock_lock(&_lock);
    _active = NO;
    os_unfair_lock_unlock(&_lock);

    AudioDeviceStop(_aggregateDeviceID, _ioProcID);
    AudioDeviceDestroyIOProcID(_aggregateDeviceID, _ioProcID);
    _ioProcID = NULL;
    // Nothing is delivered once stop has returned
    dispatch_sync(_queue, ^{});
    AudioHardwareDestroyAggregateDevice(_aggregateDeviceID);
    _aggregateDeviceID = kAudioObjectUnknown;
    if (@available(macOS 14.2, *))
    {
        AudioHardwareDestroyProcessTap(_tapID);
    }
    _tapID = kAudioObjectUnknown;
}

@end
