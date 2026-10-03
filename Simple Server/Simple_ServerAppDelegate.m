/*
    Simple_ServerAppDelegate.m
	Syphon (SDK)
	
    Copyright 2010-2011 bangnoise (Tom Butterworth) & vade (Anton Marini).
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

#import "Simple_ServerAppDelegate.h"
#import <CoreVideo/CoreVideo.h>

@interface Simple_ServerAppDelegate ()
// The size of the frames we publish, set on the main thread and read when rendering
@property (atomic, assign) NSSize frameSize;
@end

@implementation Simple_ServerAppDelegate {
    SyphonMetalServer *syServer;
    SimpleRenderer *renderer;
    id<MTLCommandQueue> commandQueue;
    CVDisplayLinkRef displayLink;

    NSTimeInterval fpsStart;
    NSUInteger fpsCount;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
	return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    // We need a MTLDevice to create a server. Here we use the one our view draws with

    id<MTLDevice> device = self.view.device;

	// Create a server.
    // - This is our only server so we don't give it a name, unless we are given one (-ServerName A): several
    //   Simple Servers can then be told apart, which is useful to test a client of several servers.

    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:@"ServerName"];
    syServer = [[SyphonMetalServer alloc] initWithName:name device:device options:nil];
    if (name.length > 0)
    {
        self.window.title = [NSString stringWithFormat:@"Simple Server \u2014 %@", name];
    }

    renderer = [[SimpleRenderer alloc] initWithDevice:device];
    commandQueue = [device newCommandQueue];

    // It's quite likely you won't want to tie your renderer to the view's
    // dimensions, but this is a useful way to show a server can vary its
    // frame size (just resize the window)
    self.frameSize = self.view.renderSize;
    self.view.delegate = self;
    // We show the frames we publish, as a client would receive them
    self.view.imageIsFlipped = YES;

	// A terrible FPS display
	fpsStart = [NSDate timeIntervalSinceReferenceDate];

    // A display link gives us steady timing, and (unlike drawing from the view) keeps publishing
    // frames when our window is hidden
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    __weak Simple_ServerAppDelegate *weakSelf = self;
    CVDisplayLinkSetOutputHandler(displayLink, ^CVReturn(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *outputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut) {
        @autoreleasepool {
            [weakSelf render];
        }
        return kCVReturnSuccess;
    });
    CVDisplayLinkStart(displayLink);
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    CVDisplayLinkStop(displayLink);
    CVDisplayLinkRelease(displayLink);
    displayLink = NULL;

	// You should always stop a server so clients know it has gone
	[syServer stop];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    self.frameSize = size;
}

- (void)drawInMTKView:(MTKView *)view
{
    // SimpleImageView does its own drawing
}

// Called by the display link, on its own thread
- (void)render
{
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

    id<MTLTexture> frame = [renderer renderFrameOfSize:self.frameSize onCommandBuffer:commandBuffer];

    // The server copies the texture, and publishes the frame once our command buffer has completed.
    // Syphon frames have their first row at the bottom of the picture (as OpenGL does) but Metal renders the
    // first row at the top, so we ask the server to flip our texture.
    [syServer publishFrameTexture:frame
                  onCommandBuffer:commandBuffer
                      imageRegion:NSMakeRect(0, 0, frame.width, frame.height)
                          flipped:YES];

    [commandBuffer commit];

    // Show what our clients see
    id<MTLTexture> image = [syServer newFrameImage];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.view.image = image;

        [self.view setNeedsDisplay:YES];

        // Monitor frame-rate

        self->fpsCount++;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval elapsed = now - self->fpsStart;
        if (elapsed > 0.5)
        {
            self.FPS = lround(self->fpsCount / elapsed);
            self->fpsCount = 0;
            self->fpsStart = now;
        }
    });
}

@end
