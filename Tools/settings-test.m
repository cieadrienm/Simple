// settings-test <picture.png>: checks the recorder's settings popover without the screen. Drives its controls as a
// user would, checks what reaches the recorder and what the controls show when the recorder is changed from outside
// (as OSC does), and saves a picture of the popover's view.
#import <Cocoa/Cocoa.h>
#import "RecorderController.h"
#import "RecorderSettingsViewController.h"
#import "ToolbarDelegate.h"

@interface OneSource : NSObject <RecorderSourceProvider>
// The last index given to selectSourceAtIndex:
@property NSInteger selected;
@end
@implementation OneSource
- (NSArray<NSString *> *)sourceTitles { return @[@"Test"]; }
- (NSString *)selectedSourceTitle { return @"Test"; }
- (NSString *)selectedSourceApplicationName { return @"Test"; }
- (void)selectSourceAtIndex:(NSInteger)index { self.selected = index; }
@end

static int failures = 0;
#define CHECK(condition, ...) do { if (!(condition)) { failures++; printf("FAILED line %d: ", __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void Act(NSControl *control)
{
    [control sendAction:control.action to:control.target];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *suite = [NSString stringWithFormat:@"settings-test-%d", getpid()];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    OneSource *sources = [[OneSource alloc] init];
    RecorderController *recorder = [[RecorderController alloc] initWithDevice:MTLCreateSystemDefaultDevice() sourceProvider:sources defaults:defaults];
    recorder.folder = NSTemporaryDirectory();

    RecorderSettingsViewController *settings = [[RecorderSettingsViewController alloc] initWithRecorder:recorder];
    NSView *view = settings.view;
    [view layoutSubtreeIfNeeded];

    // What the controls show at first
    CHECK([settings.codecPopUp.titleOfSelectedItem isEqualToString:@"H.264"], "codec shows %s", settings.codecPopUp.titleOfSelectedItem.UTF8String);
    CHECK([settings.sizePopUp.titleOfSelectedItem isEqualToString:@"Same as source"], "size shows %s", settings.sizePopUp.titleOfSelectedItem.UTF8String);
    CHECK([settings.rateComboBox.stringValue isEqualToString:@"Same as source"], "rate shows %s", settings.rateComboBox.stringValue.UTF8String);
    CHECK([settings.bitrateField.stringValue isEqualToString:@""], "bitrate shows %s", settings.bitrateField.stringValue.UTF8String);
    CHECK(settings.bitrateField.enabled, "bitrate is disabled for H.264");
    CHECK([settings.folderControl.URL.path isEqualToString:recorder.folder] || [[settings.folderControl.URL.path stringByAppendingString:@"/"] isEqualToString:recorder.folder],
          "folder shows %s", settings.folderControl.URL.path.UTF8String);

    // The user changes the controls
    [settings.codecPopUp selectItemWithTitle:@"ProRes 4444"];
    Act(settings.codecPopUp);
    CHECK([recorder.codec isEqualToString:@"prores4444"], "codec is %s", recorder.codec.UTF8String);
    CHECK(!settings.bitrateField.enabled, "bitrate is enabled for ProRes");

    [settings.sizePopUp selectItemWithTitle:@"1920 × 1080"];
    Act(settings.sizePopUp);
    CHECK(recorder.width == 1920 && recorder.height == 1080, "size is %ld x %ld", (long)recorder.width, (long)recorder.height);
    CHECK(settings.widthField.integerValue == 1920 && settings.heightField.integerValue == 1080, "fields show %s x %s",
          settings.widthField.stringValue.UTF8String, settings.heightField.stringValue.UTF8String);

    settings.widthField.stringValue = @"800";
    Act(settings.widthField);
    CHECK(recorder.width == 800 && recorder.height == 1080, "size is %ld x %ld", (long)recorder.width, (long)recorder.height);
    CHECK([settings.sizePopUp.titleOfSelectedItem isEqualToString:@"Custom"], "size shows %s", settings.sizePopUp.titleOfSelectedItem.UTF8String);

    [settings.sizePopUp selectItemWithTitle:@"Same as source"];
    Act(settings.sizePopUp);
    CHECK(recorder.width == 0 && recorder.height == 0, "size is %ld x %ld", (long)recorder.width, (long)recorder.height);
    CHECK([settings.widthField.stringValue isEqualToString:@""] && !settings.widthField.enabled, "width field shows '%s'", settings.widthField.stringValue.UTF8String);

    settings.rateComboBox.stringValue = @"25";
    Act(settings.rateComboBox);
    CHECK(recorder.fps == 25.0, "fps is %f", recorder.fps);
    settings.rateComboBox.stringValue = @"29,97";
    Act(settings.rateComboBox);
    CHECK(fabs(recorder.fps - 29.97) < 0.001, "fps is %f", recorder.fps);
    settings.rateComboBox.stringValue = @"nonsense";
    Act(settings.rateComboBox);
    CHECK(recorder.fps == 0.0, "fps is %f", recorder.fps);
    CHECK([settings.rateComboBox.stringValue isEqualToString:@"Same as source"], "rate shows %s", settings.rateComboBox.stringValue.UTF8String);

    [settings.codecPopUp selectItemWithTitle:@"HEVC"];
    Act(settings.codecPopUp);
    settings.bitrateField.stringValue = @"8.5";
    Act(settings.bitrateField);
    CHECK(recorder.bitrate == 8.5, "bitrate is %f", recorder.bitrate);

    settings.folderControl.URL = [NSURL fileURLWithPath:@"/tmp" isDirectory:YES];
    Act(settings.folderControl);
    CHECK([recorder.folder isEqualToString:@"/tmp"], "folder is %s", recorder.folder.UTF8String);
    recorder.folder = NSHomeDirectory();
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK([settings.folderControl.URL.path isEqualToString:NSHomeDirectory()], "folder shows %s", settings.folderControl.URL.path.UTF8String);

    settings.nameField.stringValue = @"take";
    Act(settings.nameField);
    CHECK([recorder.name isEqualToString:@"take"], "name is %s", recorder.name.UTF8String);

    // The recorder is changed from outside, as an OSC message does
    recorder.codec = @"prores422";
    recorder.width = 1280;
    recorder.height = 720;
    recorder.fps = 50;
    recorder.name = @"other";
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK([settings.codecPopUp.titleOfSelectedItem isEqualToString:@"ProRes 422"], "codec shows %s", settings.codecPopUp.titleOfSelectedItem.UTF8String);
    CHECK([settings.sizePopUp.titleOfSelectedItem isEqualToString:@"1280 × 720"], "size shows %s", settings.sizePopUp.titleOfSelectedItem.UTF8String);
    CHECK([settings.rateComboBox.stringValue isEqualToString:@"50"], "rate shows %s", settings.rateComboBox.stringValue.UTF8String);
    CHECK([settings.nameField.stringValue isEqualToString:@"other"], "name shows %s", settings.nameField.stringValue.UTF8String);

    // A picture of the popover, with a typical state
    recorder.codec = @"h264";
    recorder.bitrate = 12;
    recorder.name = @"";
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (argc > 1)
    {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:(NSRect){NSZeroPoint, view.fittingSize} styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        // Light, whatever the Mac is set to, so that the picture can be read on its white background
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        window.contentView = view;
        [view layoutSubtreeIfNeeded];
        NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
    }

    // The toolbar's record and settings items
    ToolbarDelegate *toolbar = [[ToolbarDelegate alloc] init];
    toolbar.recorder = recorder;
    NSArray<NSString *> *identifiers = [toolbar toolbarDefaultItemIdentifiers:(NSToolbar * _Nonnull)nil];
    CHECK([identifiers containsObject:@"RecordItemIdentifier"] && [identifiers containsObject:@"SettingsItemIdentifier"], "default items are %s", identifiers.description.UTF8String);
    NSToolbarItem *record = [toolbar toolbar:(NSToolbar * _Nonnull)nil itemForItemIdentifier:@"RecordItemIdentifier" willBeInsertedIntoToolbar:YES];
    CHECK(record.image != nil && [record.label isEqualToString:@"Record"], "record item is labelled %s", record.label.UTF8String);
    [NSApp sendAction:record.action to:record.target from:record];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK([recorder.state isEqualToString:@"recording"], "state is %s (%s)", recorder.state.UTF8String, recorder.error.UTF8String);
    CHECK([record.label isEqualToString:@"Stop"], "record item is labelled %s while recording", record.label.UTF8String);
    [NSApp sendAction:record.action to:record.target from:record];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    while (recorder.recording && limit.timeIntervalSinceNow > 0)
    {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    CHECK([recorder.state isEqualToString:@"idle"], "state is %s", recorder.state.UTF8String);
    CHECK([record.label isEqualToString:@"Record"], "record item is labelled %s when idle", record.label.UTF8String);

    NSToolbarItem *settingsItem = [toolbar toolbar:(NSToolbar * _Nonnull)nil itemForItemIdentifier:@"SettingsItemIdentifier" willBeInsertedIntoToolbar:YES];
    CHECK(settingsItem.view != nil && [settingsItem.label isEqualToString:@"Settings"], "settings item is labelled %s", settingsItem.label.UTF8String);
    NSWindow *host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [host.contentView addSubview:settingsItem.view];
    NSButton *settingsButton = (NSButton *)settingsItem.view;
    [NSApp sendAction:settingsButton.action to:settingsButton.target from:settingsButton];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    // Whether it is shown cannot be checked here: a popover does not open in a window which is not on the screen
    CHECK([toolbar.settingsPopover.contentViewController isKindOfClass:[RecorderSettingsViewController class]], "the settings button makes no popover of the settings");
    [toolbar.settingsPopover close];

    // The toolbar in a window: the source menu must stay visible, including in a narrow window (a square or
    // upright source makes one, as the window keeps the picture's shape)
    {
        NSPopUpButton *servers = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 203, 18) pullsDown:NO];
        [servers addItemsWithTitles:@[@"main view - eMotion", @"Simple Server", @"Map - AMKinectTrack"]];
        [servers selectItemAtIndex:1];
        NSBox *status = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 130, 18)];
        ToolbarDelegate *delegate = [[ToolbarDelegate alloc] init];
        [delegate setValue:servers forKey:@"availableServersMenu"];
        [delegate setValue:status forKey:@"statusBox"];
        delegate.recorder = recorder;
        delegate.sourceProvider = sources;

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 617, 617)
                                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                         backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Simple Client";
        NSToolbar *bar = [[NSToolbar alloc] initWithIdentifier:@"settings-test"];
        bar.delegate = delegate;
        bar.displayMode = NSToolbarDisplayModeIconOnly;
        window.toolbar = bar;
        for (NSNumber *width in @[@900, @617, @560, @500, @400])
        {
            [window setContentSize:NSMakeSize(width.doubleValue, width.doubleValue)];
            [window layoutIfNeeded];
            [window displayIfNeeded];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            NSArray<NSString *> *visible = [bar.visibleItems valueForKey:@"itemIdentifier"];
            if (getenv("SETTINGS_TEST_VERBOSE"))
            {
                printf("%d wide: source menu %.0f wide, visible: %s\n", width.intValue, servers.frame.size.width, [visible componentsJoinedByString:@", "].UTF8String);
            }
            CHECK([visible containsObject:@"ServersMenuItemIdentifier"], "in a window %d wide the source menu is not visible: %s", width.intValue, [visible componentsJoinedByString:@", "].UTF8String);
            CHECK([visible containsObject:@"RecordItemIdentifier"], "in a window %d wide the record button is not visible: %s", width.intValue, [visible componentsJoinedByString:@", "].UTF8String);
        }

        // Where the toolbar still has to hide it, its place in the overflow menu must work
        NSToolbarItem *serversItem = nil;
        for (NSToolbarItem *item in bar.items)
        {
            if ([item.itemIdentifier isEqualToString:@"ServersMenuItemIdentifier"]) serversItem = item;
        }
        NSMenuItem *form = serversItem.menuFormRepresentation;
        CHECK([form.title isEqualToString:@"Source"], "in the overflow menu the source menu is called '%s'", form.title.UTF8String);
        // What AppKit does before it shows the submenu
        [form.submenu.delegate menuNeedsUpdate:form.submenu];
        NSArray<NSString *> *titles = [form.submenu.itemArray valueForKey:@"title"];
        CHECK([titles isEqualToArray:servers.itemTitles], "its submenu lists %s", [titles componentsJoinedByString:@", "].UTF8String);
        CHECK(form.submenu.itemArray.count == 3 && form.submenu.itemArray[1].state == NSControlStateValueOn, "the selected source is not checked");
        // ...and so must the settings, whose button is hidden in the narrowest windows
        NSToolbarItem *hiddenSettings = nil;
        for (NSToolbarItem *item in bar.items)
        {
            if ([item.itemIdentifier isEqualToString:@"SettingsItemIdentifier"]) hiddenSettings = item;
        }
        NSMenuItem *settingsForm = hiddenSettings.menuFormRepresentation;
        CHECK([settingsForm.title isEqualToString:@"Recording Settings\u2026"], "in the overflow menu the settings are called '%s'", settingsForm.title.UTF8String);
        [NSApp sendAction:settingsForm.action to:settingsForm.target from:settingsForm];
        CHECK([delegate.settingsPopover.contentViewController isKindOfClass:[RecorderSettingsViewController class]], "the overflow menu's settings item makes no popover of the settings");
        [delegate.settingsPopover close];

        sources.selected = -1;
        NSMenuItem *third = form.submenu.itemArray.count == 3 ? form.submenu.itemArray[2] : nil;
        [NSApp sendAction:third.action to:third.target from:third];
        CHECK(sources.selected == 2, "choosing a source in the overflow menu selected %ld", (long)sources.selected);
    }

    [defaults removePersistentDomainForName:suite];
    printf(failures ? "%d checks FAILED\n" : "all checks passed\n", failures);
    return failures ? 1 : 0;
} }
