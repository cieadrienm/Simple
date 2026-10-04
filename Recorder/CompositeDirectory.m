/*
 CompositeDirectory.m
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

#import "CompositeDirectory.h"

@implementation CompositeDirectory {
    NSArray<id<SourceDirectory>> *_directories;
}

@synthesize changeHandler = _changeHandler;

- (instancetype)initWithDirectories:(NSArray<id<SourceDirectory>> *)directories
{
    self = [super init];
    if (self)
    {
        _directories = [directories copy];
    }
    return self;
}

- (NSArray<SourceDescription *> *)availableSources
{
    // One after the other: the controller keeps the first of each title
    NSMutableArray<SourceDescription *> *sources = [NSMutableArray array];
    for (id<SourceDirectory> directory in _directories)
    {
        [sources addObjectsFromArray:[directory availableSources]];
    }
    return sources;
}

- (id<FrameSource>)connectToSourceWithTitle:(NSString *)title device:(id<MTLDevice>)device
{
    for (id<SourceDirectory> directory in _directories)
    {
        BOOL listed = [[directory availableSources] indexOfObjectPassingTest:^BOOL(SourceDescription *source, NSUInteger index, BOOL *stop) {
            return [source.title isEqualToString:title];
        }] != NSNotFound;
        // A directory which lists it may have nothing alive with it: the next which lists it is asked
        id<FrameSource> source = listed ? [directory connectToSourceWithTitle:title device:device] : nil;
        if (source)
        {
            return source;
        }
    }
    return nil;
}

- (void)setChangeHandler:(void (^)(void))changeHandler
{
    _changeHandler = [changeHandler copy];
    // Weak: each directory keeps its handler, and we keep the directories
    __weak CompositeDirectory *weakSelf = self;
    for (id<SourceDirectory> directory in _directories)
    {
        directory.changeHandler = changeHandler ? ^{
            void (^handler)(void) = weakSelf.changeHandler;
            if (handler)
            {
                handler();
            }
        } : nil;
    }
}

@end
