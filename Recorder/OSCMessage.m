/*
 OSCMessage.m
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

#import "OSCMessage.h"

// Bundles nested deeper than this are not valid for our purposes
static const int kMaximumBundleDepth = 16;

// Returns the string starting at *offset and moves *offset past its padding, or nil if it is not terminated
static NSString *ReadString(const uint8_t *bytes, NSUInteger length, NSUInteger *offset)
{
    NSUInteger start = *offset;
    if (start >= length)
    {
        return nil;
    }
    const uint8_t *end = memchr(bytes + start, 0, length - start);
    if (end == NULL)
    {
        return nil;
    }
    NSUInteger size = end - (bytes + start);
    // The terminator and padding take the string to a multiple of four bytes
    NSUInteger padded = (size + 4) & ~(NSUInteger)3;
    if (start + padded > length)
    {
        return nil;
    }
    *offset = start + padded;
    return [[NSString alloc] initWithBytes:bytes + start length:size encoding:NSUTF8StringEncoding];
}

static BOOL ReadBytes(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, void *destination, NSUInteger count)
{
    if (count > length || *offset > length - count)
    {
        return NO;
    }
    memcpy(destination, bytes + *offset, count);
    *offset += count;
    return YES;
}

static void AppendString(NSMutableData *data, NSString *string)
{
    NSData *encoded = [string dataUsingEncoding:NSUTF8StringEncoding];
    [data appendData:encoded];
    static const uint8_t zeros[4] = {0, 0, 0, 0};
    [data appendBytes:zeros length:4 - (encoded.length % 4)];
}

@implementation OSCMessage

- (instancetype)initWithAddress:(NSString *)address arguments:(NSArray *)arguments
{
    self = [super init];
    if (self)
    {
        _address = [address copy];
        _arguments = [arguments copy];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %@", self.address, [self.arguments componentsJoinedByString:@" "]];
}

+ (NSArray<OSCMessage *> *)messagesFromPacket:(NSData *)packet
{
    NSMutableArray *messages = [NSMutableArray array];
    if (![self readPacket:packet.bytes length:packet.length depth:0 into:messages])
    {
        return @[];
    }
    return messages;
}

+ (BOOL)readPacket:(const uint8_t *)bytes length:(NSUInteger)length depth:(int)depth into:(NSMutableArray *)messages
{
    if (length == 0)
    {
        return NO;
    }
    if (bytes[0] == '#')
    {
        return [self readBundle:bytes length:length depth:depth into:messages];
    }
    if (bytes[0] != '/')
    {
        return NO;
    }

    NSUInteger offset = 0;
    NSString *address = ReadString(bytes, length, &offset);
    if (address == nil)
    {
        return NO;
    }

    NSMutableArray *arguments = [NSMutableArray array];
    // Very old senders omit the type tag string: such a message has no arguments we can read
    if (offset < length && bytes[offset] == ',')
    {
        NSString *tags = ReadString(bytes, length, &offset);
        if (tags == nil)
        {
            return NO;
        }
        for (NSUInteger i = 1; i < tags.length; i++)
        {
            uint32_t word;
            uint64_t doubleWord;
            switch ([tags characterAtIndex:i])
            {
                case 'i':
                    if (!ReadBytes(bytes, length, &offset, &word, 4)) return NO;
                    [arguments addObject:@((int32_t)CFSwapInt32BigToHost(word))];
                    break;
                case 'f':
                {
                    if (!ReadBytes(bytes, length, &offset, &word, 4)) return NO;
                    word = CFSwapInt32BigToHost(word);
                    float value;
                    memcpy(&value, &word, 4);
                    [arguments addObject:@(value)];
                    break;
                }
                case 'd':
                {
                    if (!ReadBytes(bytes, length, &offset, &doubleWord, 8)) return NO;
                    doubleWord = CFSwapInt64BigToHost(doubleWord);
                    double value;
                    memcpy(&value, &doubleWord, 8);
                    [arguments addObject:@(value)];
                    break;
                }
                case 'h':
                    if (!ReadBytes(bytes, length, &offset, &doubleWord, 8)) return NO;
                    [arguments addObject:@((int64_t)CFSwapInt64BigToHost(doubleWord))];
                    break;
                case 's':
                case 'S':
                {
                    NSString *string = ReadString(bytes, length, &offset);
                    if (string == nil) return NO;
                    [arguments addObject:string];
                    break;
                }
                case 'T':
                    [arguments addObject:@YES];
                    break;
                case 'F':
                    [arguments addObject:@NO];
                    break;
                // Types we skip: those without data...
                case 'N':
                case 'I':
                    break;
                // ...of four bytes...
                case 'c':
                case 'r':
                case 'm':
                    if (!ReadBytes(bytes, length, &offset, &word, 4)) return NO;
                    break;
                // ...of eight...
                case 't':
                    if (!ReadBytes(bytes, length, &offset, &doubleWord, 8)) return NO;
                    break;
                // ...and blobs, which carry their size
                case 'b':
                {
                    if (!ReadBytes(bytes, length, &offset, &word, 4)) return NO;
                    NSUInteger size = CFSwapInt32BigToHost(word);
                    NSUInteger padded = (size + 3) & ~(NSUInteger)3;
                    if (padded < size || padded > length - offset) return NO;
                    offset += padded;
                    break;
                }
                default:
                    // We cannot know how long an argument of an unknown type is
                    return NO;
            }
        }
    }
    [messages addObject:[[OSCMessage alloc] initWithAddress:address arguments:arguments]];
    return YES;
}

+ (BOOL)readBundle:(const uint8_t *)bytes length:(NSUInteger)length depth:(int)depth into:(NSMutableArray *)messages
{
    // "#bundle", its terminator, and a time tag which we ignore: messages are handled as they arrive
    static const NSUInteger headerLength = 16;
    if (depth >= kMaximumBundleDepth || length < headerLength || memcmp(bytes, "#bundle", 8) != 0)
    {
        return NO;
    }
    NSUInteger offset = headerLength;
    while (offset < length)
    {
        uint32_t word;
        if (!ReadBytes(bytes, length, &offset, &word, 4))
        {
            return NO;
        }
        NSUInteger size = CFSwapInt32BigToHost(word);
        if (size > length - offset)
        {
            return NO;
        }
        if (![self readPacket:bytes + offset length:size depth:depth + 1 into:messages])
        {
            return NO;
        }
        offset += size;
    }
    return YES;
}

- (NSData *)packet
{
    NSMutableData *data = [NSMutableData data];
    AppendString(data, self.address);

    NSMutableString *tags = [NSMutableString stringWithString:@","];
    NSMutableData *values = [NSMutableData data];
    for (id argument in self.arguments)
    {
        if ([argument isKindOfClass:[NSString class]])
        {
            [tags appendString:@"s"];
            AppendString(values, argument);
        }
        else if ([argument isKindOfClass:[NSNumber class]])
        {
            uint32_t word;
            if (CFNumberIsFloatType((__bridge CFNumberRef)argument))
            {
                [tags appendString:@"f"];
                float value = [argument floatValue];
                memcpy(&word, &value, 4);
            }
            else
            {
                [tags appendString:@"i"];
                word = (uint32_t)[argument intValue];
            }
            word = CFSwapInt32HostToBig(word);
            [values appendBytes:&word length:4];
        }
    }
    AppendString(data, tags);
    [data appendData:values];
    return data;
}

@end
