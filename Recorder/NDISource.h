/*
 NDISource.h
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
#import <Metal/Metal.h>
#import "FrameSource.h"
#import "NDILibrary.h"

NS_ASSUME_NONNULL_BEGIN

/*
 An NDI source which is connected to: a thread of its own receives its frames and delivers them as textures, their
 first row at the top, and its sound as pieces (planar floats only), until stop. The thread does not keep the source
 alive: a source which is released stops.
 */
@interface NDISource : NSObject <FrameSource>

// Connects to the source with this name and address (nil: the name alone), as the finder gives them. nil if the
// library is not available or the receiver cannot be made.
- (nullable instancetype)initWithTitle:(NSString *)title
                                  name:(NSString *)name
                                   url:(nullable NSString *)url
                               library:(NDILibrary *)library
                                device:(id<MTLDevice>)device;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
