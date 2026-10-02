/*
    SimpleClientAppDelegate.m
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

#import "SimpleClientAppDelegate.h"
#import "ServerDescriptionValueTransformer.h"
#import "ToolbarDelegate.h"

// The ports we listen on unless the environment says otherwise, which lets a second copy run beside the first
static const NSInteger kDefaultOSCPort = 9230;
static const NSInteger kDefaultOSCQueryPort = 9231;
// How long an error stays in the status display
static const NSTimeInterval kErrorDisplayTime = 6.0;

static void *RecorderErrorContext = &RecorderErrorContext;
static void *ServersContext = &ServersContext;

@interface SimpleClientAppDelegate ()
@property (readwrite, strong) RecorderController *recorder;
// The recorder's last error, for a few seconds after it happened
@property (copy) NSString *recentError;
@end

@implementation SimpleClientAppDelegate {
    SyphonMetalClient *syClient;
    IBOutlet NSArrayController *availableServersController;

    NSArray *selectedServerDescriptions;

    NSTimeInterval fpsStart;
    NSUInteger fpsCount;

    dispatch_source_t terminationSource;
}

+ (NSSet *)keyPathsForValuesAffectingStatus
{
    return [NSSet setWithObjects:@"frameWidth", @"frameHeight", @"FPS", @"selectedServerDescriptions", @"view.error",
            @"recorder.state", @"recorder.elapsed", @"recorder.recordingError", @"recentError", nil];
}

- (NSString *)status
{
    if (self.view.error)
    {
        return self.view.error.localizedDescription;
    }
    else if (self.recentError.length > 0)
    {
        return self.recentError;
    }
    else if (self.recorder.recordingError.length > 0)
    {
        // Why the last recording stopped stays until another is started: it must not be missed
        return self.recorder.recordingError;
    }

    NSString *source = @"--";
    if (self.frameWidth && self.frameHeight)
    {
        source = [NSString stringWithFormat:@"%lu x %lu : %lu FPS", (unsigned long)self.frameWidth, (unsigned long)self.frameHeight, (unsigned long)self.FPS];
    }
    if (self.recorder.recording)
    {
        NSInteger seconds = (NSInteger)self.recorder.elapsed;
        return [NSString stringWithFormat:@"\u25CF %02ld:%02ld:%02ld  %@", (long)(seconds / 3600), (long)((seconds / 60) % 60), (long)(seconds % 60), source];
    }
    return source;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
	return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    // We use an NSArrayController to populate the menu of available servers
    // Here we bind its content to SyphonServerDirectory's servers array
    [availableServersController bind:@"contentArray" toObject:[SyphonServerDirectory sharedDirectory] withKeyPath:@"servers" options:nil];
    
    // Slightly weird binding here, if anyone can neatly and non-weirdly improve on this then feel free...
    [self bind:@"selectedServerDescriptions" toObject:availableServersController withKeyPath:@"selectedObjects" options:nil];
    
    // Frames from a Syphon client have their first row at the bottom of the picture
    self.view.imageIsFlipped = YES;

    [[self.view window] setContentMinSize:(NSSize){400.0,300.0}];

    // The recorder writes the frames of the selected server to a movie. It can be driven by OSC, and describes
    // itself to OSCQuery clients.
    self.recorder = [[RecorderController alloc] initWithDevice:self.view.device
                                                sourceProvider:self
                                                      defaults:[NSUserDefaults standardUserDefaults]];
    [self.recorder addObserver:self forKeyPath:@"error" options:0 context:RecorderErrorContext];
    [availableServersController addObserver:self forKeyPath:@"arrangedObjects" options:0 context:ServersContext];

    // The toolbar's record and settings items, and File > Start Recording
    ToolbarDelegate *toolbarDelegate = (ToolbarDelegate *)self.view.window.toolbar.delegate;
    if ([toolbarDelegate isKindOfClass:[ToolbarDelegate class]])
    {
        toolbarDelegate.recorder = self.recorder;
        toolbarDelegate.sourceProvider = self;
        toolbarDelegate.window = self.view.window;
    }
    NSMenu *fileMenu = [[[NSApp mainMenu] itemWithTitle:@"File"] submenu];
    NSMenuItem *recordItem = [[NSMenuItem alloc] initWithTitle:@"Start Recording" action:@selector(toggleRecording:) keyEquivalent:@"r"];
    recordItem.target = self;
    [fileMenu insertItem:recordItem atIndex:0];
    [fileMenu insertItem:[NSMenuItem separatorItem] atIndex:1];

    NSDictionary<NSString *, NSString *> *environment = [[NSProcessInfo processInfo] environment];
    NSInteger oscPort = [environment[@"SIMPLE_OSC_PORT"] integerValue] ?: kDefaultOSCPort;
    NSInteger queryPort = [environment[@"SIMPLE_OSCQUERY_PORT"] integerValue] ?: kDefaultOSCQueryPort;
    NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey] ?: @"Simple Client";
    [self.recorder startNetworkWithOSCPort:oscPort queryPort:queryPort name:name];

    // When we are asked to terminate by a signal (kill, or a script which stops a show) quit as we do from the
    // menu, so that a movie being recorded is finished
    signal(SIGTERM, SIG_IGN);
    terminationSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(terminationSource, ^{
        // Not from this block: terminating waits for the movie to be finished, which is reported on the main
        // queue, and the main queue does nothing else until this block returns
        [NSApp performSelector:@selector(terminate:) withObject:nil afterDelay:0.0 inModes:@[NSRunLoopCommonModes]];
    });
    dispatch_resume(terminationSource);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == RecorderErrorContext)
    {
        NSString *error = self.recorder.error;
        self.recentError = error;
        if (error.length > 0)
        {
            NSLog(@"%@", error);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kErrorDisplayTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Unless another error has taken its place
                if ([self.recentError isEqualToString:error])
                {
                    self.recentError = nil;
                }
            });
        }
    }
    else if (context == ServersContext)
    {
        [self.recorder sourcesDidChange];
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (IBAction)toggleRecording:(id)sender
{
    [self.recorder toggle];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    if (menuItem.action == @selector(toggleRecording:))
    {
        menuItem.title = self.recorder.recording ? @"Stop Recording" : @"Start Recording";
    }
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if (!self.recorder.recording)
    {
        return NSTerminateNow;
    }
    // Finish the movie before we go
    [self.recorder stopWithCompletionHandler:^{
        [NSApp replyToApplicationShouldTerminate:YES];
    }];
    return NSTerminateLater;
}

#pragma mark RecorderSourceProvider

- (NSArray<NSString *> *)sourceTitles
{
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSDictionary *description in availableServersController.arrangedObjects)
    {
        [titles addObject:[ServerDescriptionValueTransformer titleForServerDescription:description]];
    }
    return titles;
}

- (NSString *)selectedSourceTitle
{
    NSDictionary *description = [selectedServerDescriptions lastObject];
    return description ? [ServerDescriptionValueTransformer titleForServerDescription:description] : nil;
}

- (NSString *)selectedSourceApplicationName
{
    return [selectedServerDescriptions lastObject][SyphonServerDescriptionAppNameKey];
}

- (void)selectSourceAtIndex:(NSInteger)index
{
    [availableServersController setSelectionIndex:index];
}

#pragma mark Servers

- (NSArray *)selectedServerDescriptions
{
    return selectedServerDescriptions;
}

- (void)setSelectedServerDescriptions:(NSArray *)descriptions
{
    if (![descriptions isEqualToArray:selectedServerDescriptions])
    {
        NSString *currentUUID = [selectedServerDescriptions lastObject][SyphonServerDescriptionUUIDKey];
        NSString *newUUID = [descriptions lastObject][SyphonServerDescriptionUUIDKey];
        BOOL uuidChange = newUUID && ![currentUUID isEqualToString:newUUID];
        selectedServerDescriptions = descriptions;

        // Was another server chosen, or did the selection move because the server we had has gone?
        BOOL chosen = YES;
        if (currentUUID)
        {
            chosen = NO;
            for (NSDictionary *description in [[SyphonServerDirectory sharedDirectory] servers])
            {
                if ([description[SyphonServerDescriptionUUIDKey] isEqualToString:currentUUID])
                {
                    chosen = YES;
                }
            }
        }

        if (!newUUID || !currentUUID || uuidChange)
        {
            // Stop our current client
            [syClient stop];
            // The recorder returns to a server which was chosen when it comes back
            [self.recorder sourceSelectionDidChange:chosen];
            // Reset our terrible FPS display
            fpsStart = [NSDate timeIntervalSinceReferenceDate];
            fpsCount = 0;
            self.FPS = 0;
            syClient = [[SyphonMetalClient alloc] initWithServerDescription:[descriptions lastObject]
                                                                     device:self.view.device
                                                                    options:nil
                                                            newFrameHandler:^(SyphonMetalClient *client) {
                // This gets called whenever the client receives a new frame.
                id<MTLTexture> frame = [client newFrameImage];

                // The recorder takes the frame here, away from the main thread
                if (frame)
                {
                    [self.recorder frameReceived:frame];
                }

                // The new-frame handler could be called from any thread, but because we update our UI we have
                // to do this on the main thread.
                dispatch_async(dispatch_get_main_queue(), ^{
                    // First we track our framerate...
                    self->fpsCount++;
                    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                    NSTimeInterval elapsed = now - self->fpsStart;
                    if (elapsed > 1.0)
                    {
                        self.FPS = lround(self->fpsCount / elapsed);
                        self->fpsStart = now;
                        self->fpsCount = 0;
                    }
                    // ...then we check to see if our dimensions display or window shape needs to be updated
                    if (frame && (self.frameWidth != frame.width || self.frameHeight != frame.height))
                    {
                        self.frameWidth = frame.width;
                        self.frameHeight = frame.height;
                        [[self.view window] setContentAspectRatio:NSMakeSize(frame.width, frame.height)];
                        [self resizeWindowForCurrentVideo];
                    }
                    // ...then update the view and mark it as needing display
                    self.view.image = frame;

                    [self.view setNeedsDisplay:YES];
                });
            }];
            
            // If we have a client we do nothing - wait until it outputs a frame
            
            // Otherwise clear the view
            if (syClient == nil)
            {
                self.view.image = nil;

                self.frameWidth = 0;
                self.frameHeight = 0;

                [self.view setNeedsDisplay:YES];
            }
        }
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{		
	[syClient stop];
	syClient = nil;
}

#pragma mark Window Sizing

- (NSSize)windowContentSizeForCurrentVideo
{
	NSSize imageSize = NSMakeSize(self.frameWidth, self.frameHeight);
	
	if (imageSize.width == 0 || imageSize.height == 0)
	{
		imageSize.width = 640;
		imageSize.height = 480;
	}

    return imageSize;
}

- (NSRect)frameRectForContentSize:(NSSize)contentSize
{
    // Make sure we are at least as big as the window's minimum content size
	NSSize minContentSize = [[self.view window] contentMinSize];
	if (contentSize.height < minContentSize.height)
	{
		CGFloat scale = minContentSize.height / contentSize.height;
		contentSize.height *= scale;
		contentSize.width *= scale;
	}
	if (contentSize.width < minContentSize.width)
	{
		CGFloat scale = minContentSize.width / contentSize.width;
		contentSize.height *= scale;
		contentSize.width *= scale;
	}
    
    NSRect contentRect = (NSRect){[[self.view window] frame].origin, contentSize};
    NSRect frameRect = [[self.view window] frameRectForContentRect:contentRect];
    
    // Move the window up (or down) so it remains rooted at the top left
    CGFloat delta = [[self.view window] frame].size.height - frameRect.size.height;
    frameRect.origin.y += delta;
    
    // Attempt to remain on-screen
    NSRect available = [[[self.view window] screen] visibleFrame];
    if (NSMaxX(frameRect) > NSMaxX(available))
    {
        frameRect.origin.x = NSMaxX(available) - frameRect.size.width;
    }
    if (NSMaxY(frameRect) > NSMaxY(available))
    {
        frameRect.origin.y = NSMaxY(available) - frameRect.size.height;
    }

    return frameRect;
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window defaultFrame:(NSRect)newFrame
{
	// We get this when the user hits the zoom box, if we're not already zoomed
	if ([window isEqual:[self.view window]])
	{
		// Resize to the current video dimensions
        return [self frameRectForContentSize:[self windowContentSizeForCurrentVideo]];        
    }
	else
	{
		return newFrame;
	}
}

- (void)resizeWindowForCurrentVideo
{
    // Resize to the correct aspect ratio, keeping as close as possible to our current dimensions
    NSSize wantedContentSize = [self windowContentSizeForCurrentVideo];
    NSSize currentSize = [[[self.view window] contentView] frame].size;
    CGFloat wr = wantedContentSize.width / currentSize.width;
    CGFloat hr = wantedContentSize.height / currentSize.height;
    CGFloat widthScaledToHeight = floor(wantedContentSize.width / hr);
    CGFloat heightScaledToWidth = floor(wantedContentSize.height / wr);
    if (widthScaledToHeight - currentSize.width < heightScaledToWidth - currentSize.height)
    {
        wantedContentSize.width /= hr;
        wantedContentSize.height /= hr;
    }
    else
    {
        wantedContentSize.width /= wr;
        wantedContentSize.height /= wr;
    }
    
    NSRect newFrame = [self frameRectForContentSize:wantedContentSize];
    [[self.view window] setFrame:newFrame display:YES animate:NO];
}


- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions
{
    return proposedOptions | NSApplicationPresentationAutoHideToolbar;
}

@end
