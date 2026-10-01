/*
 SimpleImageView.h
 Syphon (SDK)

 Copyright 2010-2014 bangnoise (Tom Butterworth) & vade (Anton Marini).
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

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

/*
 Draws a texture scaled to fit the view, preserving its aspect ratio.

 The view only draws when asked to: call setNeedsDisplay: after changing the image.
 */
@interface SimpleImageView : MTKView
@property (readwrite, strong) id<MTLTexture> image;
/*
 YES if the first row of the image is the bottom of the picture, as it is for Syphon frames
 */
@property (readwrite, assign) BOOL imageIsFlipped;
/*
 Returns the dimensions the view will render at, including any adjustment for a high-resolution display
 */
@property (readonly) NSSize renderSize;
@property (readonly) NSError *error;
@end
