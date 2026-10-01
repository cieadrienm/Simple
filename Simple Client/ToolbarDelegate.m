/*
 ToolbarDelegate.m
 Syphon (SDK)
 
 Copyright 2011 bangnoise (Tom Butterworth) & vade (Anton Marini).
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

#import "ToolbarDelegate.h"
#import "RecorderSettingsViewController.h"

static NSString * const kStatusItemIdentifier = @"StatusItemIdentifier";
static NSString * const kServersMenuItemIdentifier = @"ServersMenuItemIdentifier";
static NSString * const kRecordItemIdentifier = @"RecordItemIdentifier";
static NSString * const kSettingsItemIdentifier = @"SettingsItemIdentifier";

static void *RecorderStateContext = &RecorderStateContext;

@interface ToolbarDelegate ()
@property (readwrite) NSPopover *settingsPopover;
@end

@implementation ToolbarDelegate  {
    IBOutlet NSPopUpButton  *availableServersMenu;
    IBOutlet NSBox *statusBox;
    NSToolbarItem *recordItem;
}

- (void)dealloc
{
    [_recorder removeObserver:self forKeyPath:@"state" context:RecorderStateContext];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
    return @[kRecordItemIdentifier, kSettingsItemIdentifier, kStatusItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier, kServersMenuItemIdentifier];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
    return @[kServersMenuItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier, kStatusItemIdentifier, kRecordItemIdentifier, kSettingsItemIdentifier];
}

#pragma mark Recorder

- (void)setRecorder:(RecorderController *)recorder
{
    [_recorder removeObserver:self forKeyPath:@"state" context:RecorderStateContext];
    _recorder = recorder;
    [_recorder addObserver:self forKeyPath:@"state" options:0 context:RecorderStateContext];
    [self showRecorderState];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == RecorderStateContext)
    {
        [self showRecorderState];
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// The record item starts a recording, or stops the one in progress
- (void)showRecorderState
{
    BOOL recording = self.recorder.recording;
    NSImage *image = [NSImage imageWithSystemSymbolName:(recording ? @"stop.circle.fill" : @"record.circle")
                               accessibilityDescription:(recording ? @"Stop" : @"Record")];
    recordItem.image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor systemRedColor]]]];
    recordItem.label = recording ? @"Stop" : @"Record";
    recordItem.toolTip = recording ? @"Stop recording and finish the movie" : @"Record the source to a movie";
}

- (IBAction)toggleRecording:(id)sender
{
    [self.recorder toggle];
}

- (IBAction)showSettings:(NSButton *)sender
{
    if (self.recorder == nil)
    {
        return;
    }
    if (self.settingsPopover == nil)
    {
        NSPopover *popover = [[NSPopover alloc] init];
        popover.behavior = NSPopoverBehaviorSemitransient;
        popover.contentViewController = [[RecorderSettingsViewController alloc] initWithRecorder:self.recorder];
        self.settingsPopover = popover;
    }
    if (self.settingsPopover.shown)
    {
        [self.settingsPopover close];
    }
    else
    {
        [self.settingsPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
    }
}

#pragma mark Items

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag
{
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    if ([itemIdentifier isEqualToString:kServersMenuItemIdentifier])
    {
        [item setLabel:@"Source"];
        [item setPaletteLabel:@"Source"];
        [item setToolTip:@"Select a Syphon Server"];
        [item setView:availableServersMenu];
        NSMenuItem *menuForm = [[NSMenuItem alloc] init];
        [menuForm setMenu:[availableServersMenu menu]];
        [item setMenuFormRepresentation:menuForm];
    }
    else if ([itemIdentifier isEqualToString:kStatusItemIdentifier])
    {
        [item setLabel:@"Status"];
        [item setPaletteLabel:@"Status"];
        [item setToolTip:@"Status"];
        [statusBox setCornerRadius:4.0];
        [item setView:statusBox];
    }
    else if ([itemIdentifier isEqualToString:kRecordItemIdentifier])
    {
        [item setPaletteLabel:@"Record"];
        [item setBordered:YES];
        [item setTarget:self];
        [item setAction:@selector(toggleRecording:)];
        recordItem = item;
        [self showRecorderState];
    }
    else if ([itemIdentifier isEqualToString:kSettingsItemIdentifier])
    {
        // A button, for the popover to point at
        NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Settings"]
                                              target:self
                                              action:@selector(showSettings:)];
        [button setBezelStyle:NSBezelStyleTexturedRounded];
        [item setLabel:@"Settings"];
        [item setPaletteLabel:@"Settings"];
        [item setToolTip:@"Codec, size, frame rate, bitrate and folder of the movies recorded"];
        [item setView:button];
    }
    else
    {
        NSLog(@"Unexpect toolbar item %@", itemIdentifier);
        item = nil;
    }
    return item;
}

- (void)toolbarWillAddItem:(NSNotification *)notification
{
    NSToolbar *toolbar = notification.object;
    NSToolbarItem *item = notification.userInfo[@"item"];
    if ([item.itemIdentifier isEqualToString:kStatusItemIdentifier])
    {
        toolbar.centeredItemIdentifiers = [NSSet setWithObject:kStatusItemIdentifier];
    }
}
@end
