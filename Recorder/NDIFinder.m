/*
 NDIFinder.m
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

#import "NDIFinder.h"
#import "NDILibrary+Functions.h"

// How long the thread waits for news before it looks at stop again: what stop may wait
static const uint32_t NDIFinderWaitMilliseconds = 250;

// What the finder and its thread share: the thread holds this, not the finder, so that releasing the finder stops it
@interface NDIFinderState : NSObject
@property (readonly) NSCondition *condition;    // guards names, urls, stopping, running
@property (copy) NSArray<NSString *> *names;
@property (copy) NSArray *urls;                 // NSString or NSNull, one for each name
@property BOOL stopping;
@property BOOL running;
@property (readonly) NSRecursiveLock *callLock; // guards stopped and handler, and is held while the handler runs
@property BOOL stopped;
@property (copy, nullable) void (^handler)(void);
@end

@implementation NDIFinderState
- (instancetype)init
{
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _callLock = [[NSRecursiveLock alloc] init];
        _names = @[];
        _urls = @[];
    }
    return self;
}
@end

@implementation NDIFinder {
    NDILibrary *_library;
    NDIlib_find_instance_t _find;   // destroyed by stop, once the thread is done with it
    NDIFinderState *_state;
}

- (instancetype)initWithLibrary:(NDILibrary *)library
{
    const NDIlib_v5 *ndi = library.functions;
    if (!ndi)
        return nil;
    self = [super init];
    if (self) {
        NDIlib_find_create_t create = {0};
        create.show_local_sources = true;   // an NDI sender on this Mac is a source
        _find = ndi->find_create_v2(&create);
        if (!_find)
            return nil;
        _library = library;
        _state = [[NDIFinderState alloc] init];
        _state.running = YES;
        NDIFinderState *state = _state;
        NDIlib_find_instance_t find = _find;
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            NDIFinderRun(ndi, find, state);
        }];
        thread.name = @"NDIFinder";
        [thread start];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

static void NDIFinderRun(const NDIlib_v5 *ndi, NDIlib_find_instance_t find, NDIFinderState *state)
{
    for (;;) {
        @autoreleasepool {
            [state.condition lock];
            BOOL stopping = state.stopping;
            [state.condition unlock];
            if (stopping)
                break;
            ndi->find_wait_for_sources(find, NDIFinderWaitMilliseconds);
            // The SDK's strings live until its next call: copied at once
            uint32_t count = 0;
            const NDIlib_source_t *sources = ndi->find_get_current_sources(find, &count);
            NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
            NSMutableArray *urls = [NSMutableArray arrayWithCapacity:count];
            for (uint32_t index = 0; index < count; index++) {
                NSString *name = nil;
                NSString *url = nil;
                if (![NDIFinder copyName:&name url:&url fromSourceName:sources[index].p_ndi_name
                                     url:sources[index].p_url_address])
                    continue;
                [names addObject:name];
                [urls addObject:url ?: NSNull.null];
            }

            [state.condition lock];
            // The addresses alone may change: they are kept, but only a change of names is told
            BOOL changed = !state.stopping && ![names isEqualToArray:state.names];
            if (!state.stopping) {
                state.names = names;
                state.urls = urls;
            }
            [state.condition unlock];
            if (changed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Queued before stop, run after it: not called
                    [state.callLock lock];
                    void (^handler)(void) = state.stopped ? nil : state.handler;
                    if (handler)
                        handler();
                    [state.callLock unlock];
                });
            }
        }
    }
    [state.condition lock];
    state.running = NO;
    [state.condition broadcast];
    [state.condition unlock];
}

+ (BOOL)copyName:(NSString **)name url:(NSString **)url fromSourceName:(const char *)sourceName url:(const char *)sourceURL
{
    // @() would give nil for bytes which are not UTF-8, and adding nil to an array would end the app
    NSString *copiedName = sourceName ? [NSString stringWithUTF8String:sourceName] : nil;
    if (!copiedName) {
        *name = nil;
        *url = nil;
        return NO;
    }
    *name = copiedName;
    *url = sourceURL ? [NSString stringWithUTF8String:sourceURL] : nil;
    return YES;
}

- (NSArray<NSString *> *)sourceNames
{
    [_state.condition lock];
    NSArray<NSString *> *names = _state.names;
    [_state.condition unlock];
    return names;
}

- (BOOL)getName:(NSString **)name url:(NSString **)url forSourceNamed:(NSString *)title
{
    [_state.condition lock];
    NSUInteger index = [_state.names indexOfObject:title];
    BOOL found = index != NSNotFound;
    if (found) {
        *name = _state.names[index];
        id address = _state.urls[index];
        *url = address == NSNull.null ? nil : address;
    } else {
        *name = nil;
        *url = nil;
    }
    [_state.condition unlock];
    return found;
}

- (void (^)(void))changeHandler
{
    [_state.callLock lock];
    void (^handler)(void) = _state.handler;
    [_state.callLock unlock];
    return handler;
}

- (void)setChangeHandler:(void (^)(void))changeHandler
{
    [_state.callLock lock];
    _state.handler = changeHandler;
    [_state.callLock unlock];
}

- (void)stop
{
    // Waits for a handler which is running, so that none runs once this returns
    [_state.callLock lock];
    _state.stopped = YES;
    _state.handler = nil;
    [_state.callLock unlock];

    [_state.condition lock];
    _state.stopping = YES;
    while (_state.running)
        [_state.condition wait];
    _state.names = @[];
    _state.urls = @[];
    NDIlib_find_instance_t find = _find;
    _find = NULL;
    [_state.condition unlock];
    if (find)
        _library.functions->find_destroy(find);
}

@end
