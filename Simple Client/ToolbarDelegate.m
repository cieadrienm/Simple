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

// The source menu is as wide as it was drawn in the nib, and can shrink to this
static const CGFloat kServersMenuMinimumWidth = 80.0;
static const CGFloat kServersMenuMaximumWidth = 203.0;

static void *RecorderStateContext = &RecorderStateContext;

@interface ToolbarDelegate () <NSMenuDelegate>
@end

@interface ToolbarDelegate ()
@property (readwrite) NSPopover *settingsPopover;
@end

@implementation ToolbarDelegate  {
    IBOutlet NSPopUpButton  *availableServersMenu;
    IBOutlet NSBox *statusBox;
    NSToolbarItem *recordItem;
    NSButton *recordButton;
    // The window's title when nothing is being recorded
    NSString *idleWindowTitle;
}

+ (NSArray<NSString *> *)observedRecorderKeys
{
    return @[@"state", @"elapsed"];
}

- (void)dealloc
{
    for (NSString *key in [[self class] observedRecorderKeys])
    {
        [_recorder removeObserver:self forKeyPath:key context:RecorderStateContext];
    }
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
    for (NSString *key in [[self class] observedRecorderKeys])
    {
        [_recorder removeObserver:self forKeyPath:key context:RecorderStateContext];
    }
    _recorder = recorder;
    for (NSString *key in [[self class] observedRecorderKeys])
    {
        [_recorder addObserver:self forKeyPath:key options:0 context:RecorderStateContext];
    }
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

// Whoever started the recording (the button, the menu, an OSC message), it must be plain that we are recording:
// the button stays pressed and becomes a stop button, and the window's title counts the time
- (void)showRecorderState
{
    BOOL recording = self.recorder.recording;

    NSImage *image;
    if (recording)
    {
        // A white square on a red disc
        image = [[NSImage imageWithSystemSymbolName:@"stop.circle.fill" accessibilityDescription:@"Stop"]
                 imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor whiteColor], [NSColor systemRedColor]]]];
    }
    else
    {
        image = [[NSImage imageWithSystemSymbolName:@"record.circle" accessibilityDescription:@"Record"]
                 imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor systemRedColor]]]];
    }
    NSString *toolTip = recording ? @"Stop recording and finish the movie" : @"Record the source to a movie";
    if (recordButton.state != (recording ? NSControlStateValueOn : NSControlStateValueOff) || ![recordButton.toolTip isEqualToString:toolTip])
    {
        recordButton.image = image;
        recordButton.state = recording ? NSControlStateValueOn : NSControlStateValueOff;
        recordButton.toolTip = toolTip;
        recordItem.label = recording ? @"Stop" : @"Record";
        recordItem.toolTip = toolTip;
        recordItem.menuFormRepresentation.title = recording ? @"Stop Recording" : @"Start Recording";
    }

    NSWindow *window = self.window;
    if (window == nil)
    {
        return;
    }
    if (idleWindowTitle == nil)
    {
        idleWindowTitle = [window.title copy];
    }
    NSString *title = idleWindowTitle;
    if (self.notice.length > 0)
    {
        title = [@"\u26A0 " stringByAppendingString:self.notice];
    }
    else if (recording)
    {
        NSInteger seconds = (NSInteger)self.recorder.elapsed;
        title = [NSString stringWithFormat:@"\u25CF %02ld:%02ld:%02ld \u2014 %@", (long)(seconds / 3600), (long)((seconds / 60) % 60), (long)(seconds % 60), idleWindowTitle];
    }
    if (![window.title isEqualToString:title])
    {
        window.title = title;
    }
}

- (void)setNotice:(NSString *)notice
{
    _notice = [notice copy];
    [self showRecorderState];
}

- (IBAction)toggleRecording:(id)sender
{
    [self.recorder toggle];
    // A click toggles the button by itself: it shows the recorder's state, which may not have changed
    [self showRecorderState];
}

// sender is the settings button, or its item in the toolbar's overflow menu when the window is too narrow for it
- (IBAction)showSettings:(id)sender
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
    else if ([sender isKindOfClass:[NSView class]] && [sender window] != nil)
    {
        [self.settingsPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:NSRectEdgeMaxY];
    }
    else
    {
        // The button is not in the toolbar: under the toolbar, in the middle of the window
        NSView *content = availableServersMenu.window.contentView ?: [NSApp mainWindow].contentView;
        if (content == nil)
        {
            return;
        }
        NSRect top = NSMakeRect(NSMidX(content.bounds) - 1.0, content.isFlipped ? 0.0 : NSMaxY(content.bounds) - 1.0, 2.0, 1.0);
        [self.settingsPopover showRelativeToRect:top ofView:content preferredEdge:content.isFlipped ? NSRectEdgeMaxY : NSRectEdgeMinY];
    }
}

#pragma mark Sources in the overflow menu

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    // The same sources as the menu in the toolbar, which bindings keep up to date
    [menu removeAllItems];
    NSInteger selected = availableServersMenu.indexOfSelectedItem;
    [availableServersMenu.itemTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        NSMenuItem *source = [menu addItemWithTitle:title action:@selector(chooseSource:) keyEquivalent:@""];
        source.target = self;
        source.tag = index;
        source.state = ((NSInteger)index == selected) ? NSControlStateValueOn : NSControlStateValueOff;
    }];
}

- (IBAction)chooseSource:(NSMenuItem *)sender
{
    [self.sourceProvider selectSourceAtIndex:sender.tag];
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
        // The window keeps the shape of the picture, so it can be narrow: the menu shrinks to make room, and is
        // among the last items the toolbar hides
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [item setMinSize:NSMakeSize(kServersMenuMinimumWidth, availableServersMenu.frame.size.height)];
        [item setMaxSize:NSMakeSize(kServersMenuMaximumWidth, availableServersMenu.frame.size.height)];
#pragma clang diagnostic pop
        [item setVisibilityPriority:NSToolbarItemVisibilityPriorityHigh];
        // Where it is hidden all the same, the toolbar's overflow menu has the sources as a submenu
        NSMenuItem *menuForm = [[NSMenuItem alloc] initWithTitle:@"Source" action:NULL keyEquivalent:@""];
        NSMenu *sources = [[NSMenu alloc] initWithTitle:@"Source"];
        sources.delegate = self;
        menuForm.submenu = sources;
        [item setMenuFormRepresentation:menuForm];
    }
    else if ([itemIdentifier isEqualToString:kStatusItemIdentifier])
    {
        [item setLabel:@"Status"];
        [item setPaletteLabel:@"Status"];
        [item setToolTip:@"Status"];
        [statusBox setCornerRadius:4.0];
        [item setView:statusBox];
        // The first to go when the window is narrow
        [item setVisibilityPriority:NSToolbarItemVisibilityPriorityLow];
    }
    else if ([itemIdentifier isEqualToString:kRecordItemIdentifier])
    {
        // A button which stays pressed while recording
        NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"record.circle" accessibilityDescription:@"Record"]
                                              target:self
                                              action:@selector(toggleRecording:)];
        [button setButtonType:NSButtonTypePushOnPushOff];
        [button setBezelStyle:NSBezelStyleTexturedRounded];
        [item setLabel:@"Record"];
        [item setPaletteLabel:@"Record"];
        [item setView:button];
        [item setVisibilityPriority:NSToolbarItemVisibilityPriorityHigh];
        NSMenuItem *menuForm = [[NSMenuItem alloc] initWithTitle:@"Start Recording" action:@selector(toggleRecording:) keyEquivalent:@""];
        menuForm.target = self;
        [item setMenuFormRepresentation:menuForm];
        recordItem = item;
        recordButton = button;
        // Not yet in the state it shows
        recordButton.state = NSControlStateValueMixed;
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
        NSMenuItem *menuForm = [[NSMenuItem alloc] initWithTitle:@"Recording Settings\u2026" action:@selector(showSettings:) keyEquivalent:@""];
        menuForm.target = self;
        [item setMenuFormRepresentation:menuForm];
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
