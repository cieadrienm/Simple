/*
 NDIFinder.h
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

// Private to Recorder/ and to the tests' support: excluded from the module Swift sees (Recorder/module.modulemap)

#import <Foundation/Foundation.h>
#import "NDILibrary.h"

NS_ASSUME_NONNULL_BEGIN

/*
 The NDI sources on the network, this Mac's own senders included. A thread of its own looks for them until stop.
 The thread does not keep the finder alive: a finder which is released stops, so whoever owns it (NDIDirectory) ends it
 by releasing it.
 */
@interface NDIFinder : NSObject

// nil if the library is not available
- (nullable instancetype)initWithLibrary:(NDILibrary *)library;
- (instancetype)init NS_UNAVAILABLE;

// The names of the sources found, exactly as NDI gives them ("HOST (name)"), in the order found. Any thread.
// Empty once stopped.
@property (readonly, copy) NSArray<NSString *> *sourceNames;

// The source's name and address (nil when NDI gives none), copies of the finder's which stay valid whatever it finds
// next; NO, and both nil, if no source has this name (or no longer). Any thread. To connect, a receiver builds its own NDIlib_source_t
// from their UTF8String, and keeps these strings for the receiver's whole life: NDI may read them after recv_create.
- (BOOL)getName:(NSString * _Nullable * _Nonnull)name url:(NSString * _Nullable * _Nonnull)url forSourceNamed:(NSString *)title;

// A source as the SDK gives it, copied: NO, and both nil, when it has no name or one which is not UTF-8 (any bytes may
// come from the network); a url which is NULL or not UTF-8 is nil
+ (BOOL)copyName:(NSString * _Nullable * _Nonnull)name url:(NSString * _Nullable * _Nonnull)url
  fromSourceName:(nullable const char *)sourceName url:(nullable const char *)sourceURL;

// Called on the main queue when sourceNames has really changed, never once stop has returned
@property (copy, nullable) void (^changeHandler)(void);

// Ends the thread and waits for it (a quarter of a second at most). Any thread, any number of times.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
