/*
 OSCReceiver.m
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

#import "OSCReceiver.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>

static const NSInteger kPortsToTry = 16;
// The largest datagram UDP can carry
static const size_t kMaximumPacketSize = 65535;

@interface OSCReceiver ()
@property (readwrite) NSInteger port;
@end

@implementation OSCReceiver {
    dispatch_queue_t _queue;
    dispatch_source_t _source;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _queue = dispatch_queue_create("net.am-cb.simple.osc-receiver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (BOOL)startOnPort:(NSInteger)preferredPort handler:(void (^)(OSCMessage *message))handler
{
    [self stop];

    int descriptor = -1;
    NSInteger port = 0;
    for (NSInteger candidate = preferredPort; candidate < preferredPort + kPortsToTry && candidate <= 65535; candidate++)
    {
        descriptor = socket(AF_INET, SOCK_DGRAM, 0);
        if (descriptor < 0)
        {
            NSLog(@"OSC: socket() failed: %s", strerror(errno));
            return NO;
        }
        // No SO_REUSEADDR or SO_REUSEPORT: if another application (or another copy of this one) has the port,
        // we must not share it, as only one of us would receive each message
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons((uint16_t)candidate);
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) == 0)
        {
            port = candidate;
            break;
        }
        close(descriptor);
        descriptor = -1;
    }
    if (descriptor < 0)
    {
        NSLog(@"OSC: no free UDP port from %ld to %ld", (long)preferredPort, (long)(preferredPort + kPortsToTry - 1));
        return NO;
    }
    fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK);

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, descriptor, 0, _queue);
    dispatch_source_set_event_handler(source, ^{
        uint8_t *buffer = malloc(kMaximumPacketSize);
        ssize_t length;
        // Take everything which has arrived
        while ((length = recv(descriptor, buffer, kMaximumPacketSize, 0)) > 0)
        {
            NSArray<OSCMessage *> *messages = [OSCMessage messagesFromPacket:[NSData dataWithBytes:buffer length:length]];
            if (messages.count > 0)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (OSCMessage *message in messages)
                    {
                        handler(message);
                    }
                });
            }
        }
        free(buffer);
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(descriptor);
    });
    _source = source;
    self.port = port;
    dispatch_resume(source);
    return YES;
}

- (void)stop
{
    dispatch_source_t source = _source;
    if (source == nil)
    {
        return;
    }
    _source = nil;
    self.port = 0;
    // Wait for the socket to be closed, so the port is free when we return
    dispatch_semaphore_t closed = dispatch_semaphore_create(0);
    dispatch_source_set_cancel_handler(source, ^{
        close((int)dispatch_source_get_handle(source));
        dispatch_semaphore_signal(closed);
    });
    dispatch_source_cancel(source);
    dispatch_semaphore_wait(closed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
}

@end
