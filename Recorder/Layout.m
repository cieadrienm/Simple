/*
 Layout.m
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

#import "Layout.h"

// What a source which was never seen counts as
static const NSSize kUnknownSourceSize = {1920.0, 1080.0};

static CGFloat EvenUp(CGFloat value)
{
    NSInteger whole = (NSInteger)ceil(value);
    return MAX(whole + (whole % 2), 2);
}

static CGFloat EvenDown(CGFloat value)
{
    NSInteger whole = (NSInteger)floor(value);
    return MAX(whole - (whole % 2), 2);
}

@implementation Layout

+ (NSArray<NSString *> *)kindNames
{
    return @[@"row", @"column", @"grid", @"focus"];
}

+ (NSString *)nameForKind:(LayoutKind)kind
{
    NSArray<NSString *> *names = [self kindNames];
    return (kind >= 0 && kind < (NSInteger)names.count) ? names[kind] : names[0];
}

+ (BOOL)getKind:(LayoutKind *)kind forName:(NSString *)name
{
    NSUInteger index = [[self kindNames] indexOfObject:name.lowercaseString];
    if (index == NSNotFound)
    {
        return NO;
    }
    *kind = (LayoutKind)index;
    return YES;
}

- (instancetype)initWithKind:(LayoutKind)kind
                 sourceSizes:(NSArray *)sourceSizes
                         gap:(NSInteger)gap
                 fittingSize:(NSSize)fittingSize
{
    self = [super init];
    if (self)
    {
        _kind = kind;
        NSUInteger count = sourceSizes.count;
        NSSize sizes[count > 0 ? count : 1];
        for (NSUInteger index = 0; index < count; index++)
        {
            id value = sourceSizes[index];
            NSSize size = [value isKindOfClass:[NSValue class]] ? [value sizeValue] : NSZeroSize;
            sizes[index] = (size.width >= 1.0 && size.height >= 1.0) ? size : kUnknownSourceSize;
        }
        CGFloat space = MAX(gap, 0);

        NSRect frames[count > 0 ? count : 1];
        NSSize picture = kUnknownSourceSize;
        if (count == 1)
        {
            frames[0] = (NSRect){NSZeroPoint, sizes[0]};
            picture = sizes[0];
        }
        else if (count > 1 && kind == LayoutKindRow)
        {
            CGFloat height = 0.0;
            for (NSUInteger index = 0; index < count; index++)
            {
                height = MAX(height, sizes[index].height);
            }
            CGFloat x = 0.0;
            for (NSUInteger index = 0; index < count; index++)
            {
                CGFloat width = MAX(round(sizes[index].width * height / sizes[index].height), 1.0);
                frames[index] = NSMakeRect(x, 0.0, width, height);
                x += width + space;
            }
            picture = NSMakeSize(x - space, height);
        }
        else if (count > 1 && kind == LayoutKindColumn)
        {
            CGFloat width = 0.0;
            for (NSUInteger index = 0; index < count; index++)
            {
                width = MAX(width, sizes[index].width);
            }
            CGFloat y = 0.0;
            for (NSUInteger index = 0; index < count; index++)
            {
                CGFloat height = MAX(round(sizes[index].height * width / sizes[index].width), 1.0);
                frames[index] = NSMakeRect(0.0, y, width, height);
                y += height + space;
            }
            picture = NSMakeSize(width, y - space);
        }
        else if (count > 1 && kind == LayoutKindGrid)
        {
            NSSize cell = NSZeroSize;
            for (NSUInteger index = 0; index < count; index++)
            {
                cell.width = MAX(cell.width, sizes[index].width);
                cell.height = MAX(cell.height, sizes[index].height);
            }
            NSUInteger columns = (NSUInteger)ceil(sqrt((double)count));
            NSUInteger rows = (count + columns - 1) / columns;
            for (NSUInteger index = 0; index < count; index++)
            {
                CGFloat scale = MIN(cell.width / sizes[index].width, cell.height / sizes[index].height);
                CGFloat width = MAX(round(sizes[index].width * scale), 1.0), height = MAX(round(sizes[index].height * scale), 1.0);
                CGFloat x = (index % columns) * (cell.width + space), y = (index / columns) * (cell.height + space);
                frames[index] = NSMakeRect(x + floor((cell.width - width) / 2.0), y + floor((cell.height - height) / 2.0), width, height);
            }
            picture = NSMakeSize(columns * cell.width + (columns - 1) * space, rows * cell.height + (rows - 1) * space);
        }
        else if (count > 1)
        {
            // Focus
            frames[0] = (NSRect){NSZeroPoint, sizes[0]};
            NSUInteger others = count - 1;
            CGFloat share = MAX(floor((sizes[0].height - space * (others - 1)) / others), 1.0);
            CGFloat column = 0.0;
            for (NSUInteger index = 1; index < count; index++)
            {
                CGFloat width = MAX(round(sizes[index].width * share / sizes[index].height), 1.0);
                frames[index] = NSMakeRect(0.0, (index - 1) * (share + space), width, share);
                column = MAX(column, width);
            }
            CGFloat left = sizes[0].width + space;
            for (NSUInteger index = 1; index < count; index++)
            {
                frames[index].origin.x = left + floor((column - frames[index].size.width) / 2.0);
            }
            picture = NSMakeSize(left + column, sizes[0].height);
        }

        if (fittingSize.width >= 1.0 && fittingSize.height >= 1.0)
        {
            // The whole picture, scaled by one factor and centred
            NSSize target = NSMakeSize(EvenDown(fittingSize.width), EvenDown(fittingSize.height));
            CGFloat scale = MIN(target.width / picture.width, target.height / picture.height);
            // (the dimension which fits exactly leaves a space of zero, or of a hair less in floating point)
            CGFloat left = MAX(floor((target.width - picture.width * scale) / 2.0 + 0.001), 0.0);
            CGFloat top = MAX(floor((target.height - picture.height * scale) / 2.0 + 0.001), 0.0);
            for (NSUInteger index = 0; index < count; index++)
            {
                // Edges are scaled, not sizes, so that sources which did not overlap still do not
                CGFloat minX = floor(NSMinX(frames[index]) * scale), maxX = floor(NSMaxX(frames[index]) * scale);
                CGFloat minY = floor(NSMinY(frames[index]) * scale), maxY = floor(NSMaxY(frames[index]) * scale);
                frames[index] = NSMakeRect(left + minX, top + minY, MAX(maxX - minX, 1.0), MAX(maxY - minY, 1.0));
            }
            _size = target;
        }
        else
        {
            _size = NSMakeSize(EvenUp(picture.width), EvenUp(picture.height));
        }

        NSMutableArray<NSValue *> *values = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger index = 0; index < count; index++)
        {
            [values addObject:[NSValue valueWithRect:frames[index]]];
        }
        _frames = [values copy];
    }
    return self;
}

@end
