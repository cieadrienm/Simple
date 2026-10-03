/*
 Layout.h
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

typedef NS_ENUM(NSInteger, LayoutKind) {
    LayoutKindRow,      // side by side
    LayoutKindColumn,   // stacked
    LayoutKindGrid,     // a mosaic
    LayoutKindFocus     // the first large, the others in a column on its right
};

/*
 Where the sources go in the assembled picture, and how large that picture is.

 Without a size to fit, the picture is as large as the sources need:
 - row: every source at the height of the tallest, side by side
 - column: every source at the width of the widest, one above the other
 - grid: cells the size of the largest source, as many columns as the square root of their number rounded up, each
   source fitted in its cell
 - focus: the first source at its own size, the others sharing its height in a column on its right
 One source is itself, whatever the kind.
 */
@interface Layout : NSObject
// "row", "column", "grid", "focus"
+ (NSArray<NSString *> *)kindNames;
+ (NSString *)nameForKind:(LayoutKind)kind;
+ (BOOL)getKind:(LayoutKind *)kind forName:(NSString *)name;

// sourceSizes: the size of each source's frames (an NSValue of an NSSize). NSNull, or a size with a zero, for a
// source which was never seen: it counts as 1920 × 1080.
// gap: pixels between sources.
// fittingSize: the size the picture is fitted into, without distortion, with bars. If either dimension is 0 the
// picture has its automatic size.
- (instancetype)initWithKind:(LayoutKind)kind
                 sourceSizes:(NSArray *)sourceSizes
                         gap:(NSInteger)gap
                 fittingSize:(NSSize)fittingSize;

@property (readonly) LayoutKind kind;
// The size of the picture in pixels: even numbers
@property (readonly) NSSize size;
// The rectangle of each source's picture, in whole pixels from the top left of the picture, in the sources' order
@property (readonly, copy) NSArray<NSValue *> *frames;
@end

NS_ASSUME_NONNULL_END
