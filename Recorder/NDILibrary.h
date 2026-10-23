/*
 NDILibrary.h
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

NS_ASSUME_NONNULL_BEGIN

// NDI's library, loaded at run time: SimpleRecorder works without it, and does not ship a copy it may not redistribute.
// This header does not include the SDK's headers (NDILibrary+Functions.h does), so Swift never needs them.
@interface NDILibrary : NSObject

// The library found in the places of +candidatePathsWithEnvironment:bundlePath:, loaded once. Never nil: see available.
+ (NDILibrary *)sharedLibrary;

// Where to look for libndi.dylib, in order: SIMPLE_NDI_LIBRARY alone when it is set; otherwise the app's
// Contents/Frameworks, NDI's runtime ($NDI_RUNTIME_DIR_V6, when set), /usr/local/lib, then the NDI SDK for Apple.
+ (NSArray<NSString *> *)candidatePathsWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment
                                             bundlePath:(NSString *)bundlePath;

// A library at a path, for tests. Never nil.
- (instancetype)initWithPath:(nullable NSString *)path;
- (instancetype)init NS_UNAVAILABLE;

@property (readonly, getter=isAvailable) BOOL available;
// "NDI SDK APPLE 6.1.1" or such; empty if it is not available
@property (readonly, copy) NSString *version;
// Where it was loaded from; nil if it is not available
@property (readonly, nullable, copy) NSString *path;
// Why it is not available ("libndi.dylib was not found", "… is not an NDI library", "this Mac cannot run NDI"); empty if it is
@property (readonly, copy) NSString *reason;

@end

NS_ASSUME_NONNULL_END
