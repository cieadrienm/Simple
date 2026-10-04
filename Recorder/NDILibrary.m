/*
 NDILibrary.m
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

#import "NDILibrary+Functions.h"
#import <dlfcn.h>

@implementation NDILibrary {
    const NDIlib_v5 *_functions;
}

+ (NDILibrary *)sharedLibrary
{
    static NDILibrary *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *candidates = [self candidatePathsWithEnvironment:NSProcessInfo.processInfo.environment
                                                                   bundlePath:NSBundle.mainBundle.bundlePath];
        NDILibrary *firstFailure = nil;
        for (NSString *candidate in candidates) {
            if (![NSFileManager.defaultManager fileExistsAtPath:candidate])
                continue;
            NDILibrary *library = [[NDILibrary alloc] initWithPath:candidate];
            if (library.available) {
                shared = library;
                return;
            }
            if (!firstFailure)
                firstFailure = library;
        }
        shared = firstFailure ?: [[NDILibrary alloc] initWithReason:
            [NSString stringWithFormat:@"libndi.dylib was not found in %@", [candidates componentsJoinedByString:@", "]]];
    });
    return shared;
}

+ (NSArray<NSString *> *)candidatePathsWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment
                                             bundlePath:(NSString *)bundlePath
{
    NSString *chosen = environment[@"SIMPLE_NDI_LIBRARY"];
    if (chosen.length > 0)
        return @[chosen];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [paths addObject:[bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/libndi.dylib"]];
    NSString *runtime = environment[@"NDI_RUNTIME_DIR_V6"];
    if (runtime.length > 0)
        [paths addObject:[runtime stringByAppendingPathComponent:@"libndi.dylib"]];
    [paths addObject:@"/usr/local/lib/libndi.dylib"];
    [paths addObject:@"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"];
    return paths;
}

- (instancetype)initWithReason:(NSString *)reason
{
    self = [super init];
    if (self) {
        _version = @"";
        _reason = [reason copy];
    }
    return self;
}

- (instancetype)initWithPath:(NSString *)path
{
    if (path.length == 0)
        return [self initWithReason:@"libndi.dylib was not found"];
    // No test of the file first: the system's libraries live in dyld's cache, not on disk
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path])
            return [self initWithReason:[NSString stringWithFormat:@"libndi.dylib was not found at %@", path]];
        const char *error = dlerror();
        return [self initWithReason:[NSString stringWithFormat:@"%@ is not an NDI library (%s)", path, error ?: "it does not load"]];
    }
    const NDIlib_v5 *(*load)(void) = (const NDIlib_v5 *(*)(void))dlsym(handle, "NDIlib_v5_load");
    const NDIlib_v5 *functions = load ? load() : NULL;
    if (!functions) {
        // Not NDI's: nothing of it is used, so it need not stay mapped
        dlclose(handle);
        return [self initWithReason:[NSString stringWithFormat:@"%@ is not an NDI library", path]];
    }
    // NDI's library stays loaded as long as the process, and destroy() is never called: senders and receivers may be
    // anywhere when the app quits
    if (!functions->is_supported_CPU() || !functions->initialize())
        return [self initWithReason:@"this Mac cannot run NDI"];

    self = [self initWithReason:@""];
    if (self) {
        _functions = functions;
        _available = YES;
        _path = [path copy];
        const char *version = functions->version();
        _version = version ? @(version) : @"";
    }
    return self;
}

- (const NDIlib_v5 *)functions
{
    return _functions;
}

@end
