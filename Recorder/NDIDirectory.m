/*
 NDIDirectory.m
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

#import "NDIDirectory.h"
#import "NDIFinder.h"

@implementation NDIDirectory {
    NDIFinder *_finder;     // nil without the library; stopped when this is released, with it
}

@synthesize changeHandler = _changeHandler;

- (instancetype)initWithLibrary:(NDILibrary *)library
{
    self = [super init];
    if (self) {
        _finder = [[NDIFinder alloc] initWithLibrary:library];
        __weak NDIDirectory *weakSelf = self;
        _finder.changeHandler = ^{
            NDIDirectory *directory = weakSelf;
            if (directory.changeHandler)
                directory.changeHandler();
        };
    }
    return self;
}

- (void)dealloc
{
    [_finder stop];
}

- (NSArray<SourceDescription *> *)availableSources
{
    NSMutableArray<SourceDescription *> *sources = [NSMutableArray array];
    for (NSString *name in _finder.sourceNames)
        [sources addObject:[[SourceDescription alloc] initWithTitle:name detail:@"NDI" kind:FrameSourceKindNDI]];
    return sources;
}

- (id<FrameSource>)connectToSourceWithTitle:(NSString *)title device:(id<MTLDevice>)device
{
    // Receivers come next
    return nil;
}

@end
