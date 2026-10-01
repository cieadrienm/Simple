/*
 OSCMessage.h
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

/*
 An Open Sound Control message: an address and its arguments.
 */
@interface OSCMessage : NSObject
@property (readonly, copy) NSString *address;
// NSNumber for the types i, f, d, h, T and F; NSString for s and S. Arguments of other types are skipped.
@property (readonly, copy) NSArray *arguments;
- (instancetype)initWithAddress:(NSString *)address arguments:(NSArray *)arguments;
// The messages in a packet, including those in bundles. An empty array if the packet is not valid OSC.
+ (NSArray<OSCMessage *> *)messagesFromPacket:(NSData *)packet;
// The message as a packet. NSString is sent as s; NSNumber as i when it holds an integer, as f otherwise.
- (NSData *)packet;
@end

NS_ASSUME_NONNULL_END
