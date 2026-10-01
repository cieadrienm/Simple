/*
 RecorderSettingsViewController.m
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

#import "RecorderSettingsViewController.h"
#import "MovieRecorder.h"

static NSString * const kSameAsSource = @"Same as source";
static NSString * const kCustom = @"Custom";

static void *RecorderContext = &RecorderContext;

// The titles of the codecs, in the order of +[MovieRecorderSettings codecNames]
static NSArray<NSString *> *CodecTitles(void)
{
    return @[@"H.264", @"HEVC", @"ProRes 422", @"ProRes 4444"];
}

// The sizes offered, as width then height
static NSArray<NSArray<NSNumber *> *> *SizePresets(void)
{
    return @[@[@1280, @720], @[@1920, @1080], @[@3840, @2160]];
}

static NSString *SizeTitle(NSInteger width, NSInteger height)
{
    return [NSString stringWithFormat:@"%ld \u00D7 %ld", (long)width, (long)height];
}

@interface RecorderSettingsViewController ()
@property (readwrite) NSPopUpButton *codecPopUp;
@property (readwrite) NSPopUpButton *sizePopUp;
@property (readwrite) NSTextField *widthField;
@property (readwrite) NSTextField *heightField;
@property (readwrite) NSComboBox *rateComboBox;
@property (readwrite) NSTextField *bitrateField;
@property (readwrite) NSPathControl *folderControl;
@property (readwrite) NSTextField *nameField;
@end

@implementation RecorderSettingsViewController {
    RecorderController *_recorder;
    NSTextField *_portsLabel;
    BOOL _observing;
}

+ (NSArray<NSString *> *)observedKeys
{
    return @[@"codec", @"width", @"height", @"fps", @"bitrate", @"folder", @"name", @"oscPort", @"oscQueryPort"];
}

- (instancetype)initWithRecorder:(RecorderController *)recorder
{
    self = [super initWithNibName:nil bundle:nil];
    if (self)
    {
        _recorder = recorder;
    }
    return self;
}

- (void)dealloc
{
    if (_observing)
    {
        for (NSString *key in [[self class] observedKeys])
        {
            [_recorder removeObserver:self forKeyPath:key context:RecorderContext];
        }
    }
}

#pragma mark View

- (NSTextField *)labelWithString:(NSString *)string
{
    NSTextField *label = [NSTextField labelWithString:string];
    label.alignment = NSTextAlignmentRight;
    return label;
}

- (NSPopUpButton *)popUpWithAction:(SEL)action
{
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popUp.target = self;
    popUp.action = action;
    return popUp;
}

- (NSTextField *)fieldWithPlaceholder:(NSString *)placeholder width:(CGFloat)width action:(SEL)action
{
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = placeholder;
    field.target = self;
    field.action = action;
    [field.widthAnchor constraintEqualToConstant:width].active = YES;
    return field;
}

- (void)loadView
{
    self.codecPopUp = [self popUpWithAction:@selector(codecChanged:)];
    [self.codecPopUp addItemsWithTitles:CodecTitles()];

    self.sizePopUp = [self popUpWithAction:@selector(sizePresetChanged:)];
    [self.sizePopUp addItemWithTitle:kSameAsSource];
    for (NSArray<NSNumber *> *size in SizePresets())
    {
        [self.sizePopUp addItemWithTitle:SizeTitle(size[0].integerValue, size[1].integerValue)];
    }
    [self.sizePopUp addItemWithTitle:kCustom];

    self.widthField = [self fieldWithPlaceholder:@"width" width:64.0 action:@selector(sizeFieldChanged:)];
    self.heightField = [self fieldWithPlaceholder:@"height" width:64.0 action:@selector(sizeFieldChanged:)];
    NSStackView *sizeFields = [NSStackView stackViewWithViews:@[self.widthField, [NSTextField labelWithString:@"\u00D7"], self.heightField]];
    sizeFields.spacing = 4.0;

    self.rateComboBox = [[NSComboBox alloc] initWithFrame:NSZeroRect];
    [self.rateComboBox addItemsWithObjectValues:@[kSameAsSource, @"24", @"25", @"30", @"50", @"60"]];
    self.rateComboBox.target = self;
    self.rateComboBox.action = @selector(rateChanged:);
    [self.rateComboBox.widthAnchor constraintEqualToConstant:150.0].active = YES;
    NSStackView *rate = [NSStackView stackViewWithViews:@[self.rateComboBox, [NSTextField labelWithString:@"frames per second"]]];

    self.bitrateField = [self fieldWithPlaceholder:@"Automatic" width:80.0 action:@selector(bitrateChanged:)];
    NSStackView *bitrate = [NSStackView stackViewWithViews:@[self.bitrateField, [NSTextField labelWithString:@"Mbit/s"]]];

    // A pop-up of the folder and those which contain it, with an item to choose another
    self.folderControl = [[NSPathControl alloc] initWithFrame:NSZeroRect];
    self.folderControl.pathStyle = NSPathStylePopUp;
    self.folderControl.allowedTypes = @[@"public.folder"];
    self.folderControl.delegate = self;
    self.folderControl.target = self;
    self.folderControl.action = @selector(folderChanged:);
    [self.folderControl.widthAnchor constraintEqualToConstant:240.0].active = YES;

    self.nameField = [self fieldWithPlaceholder:@"Source and date" width:240.0 action:@selector(nameChanged:)];

    _portsLabel = [NSTextField labelWithString:@""];
    _portsLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    _portsLabel.textColor = [NSColor secondaryLabelColor];
    _portsLabel.selectable = YES;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[self labelWithString:@"Codec:"], self.codecPopUp],
        @[[self labelWithString:@"Size:"], self.sizePopUp],
        @[[NSGridCell emptyContentView], sizeFields],
        @[[self labelWithString:@"Frame rate:"], rate],
        @[[self labelWithString:@"Bitrate:"], bitrate],
        @[[self labelWithString:@"Folder:"], self.folderControl],
        @[[self labelWithString:@"Name:"], self.nameField],
        @[[NSGridCell emptyContentView], _portsLabel]
    ]];
    grid.rowSpacing = 8.0;
    grid.columnSpacing = 8.0;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
    [view addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16.0],
        [grid.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-16.0],
        [grid.topAnchor constraintEqualToAnchor:view.topAnchor constant:16.0],
        [grid.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-16.0]
    ]];
    self.view = view;

    for (NSString *key in [[self class] observedKeys])
    {
        [_recorder addObserver:self forKeyPath:key options:0 context:RecorderContext];
    }
    _observing = YES;
    [self showSettings];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == RecorderContext)
    {
        [self showSettings];
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// Makes the controls show the recorder's settings
- (void)showSettings
{
    MovieCodec codec = MovieCodecH264;
    [MovieRecorderSettings getCodec:&codec forName:_recorder.codec];
    [self.codecPopUp selectItemAtIndex:codec];

    NSInteger width = _recorder.width, height = _recorder.height;
    BOOL sameAsSource = width == 0 || height == 0;
    NSString *sizeTitle = sameAsSource ? kSameAsSource : SizeTitle(width, height);
    if ([self.sizePopUp itemWithTitle:sizeTitle] == nil)
    {
        sizeTitle = kCustom;
    }
    [self.sizePopUp selectItemWithTitle:sizeTitle];
    self.widthField.stringValue = sameAsSource ? @"" : [NSString stringWithFormat:@"%ld", (long)width];
    self.heightField.stringValue = sameAsSource ? @"" : [NSString stringWithFormat:@"%ld", (long)height];
    self.widthField.enabled = !sameAsSource;
    self.heightField.enabled = !sameAsSource;

    self.rateComboBox.stringValue = _recorder.fps > 0.0 ? [NSString stringWithFormat:@"%g", _recorder.fps] : kSameAsSource;

    // ProRes has no bitrate to choose
    BOOL hasBitrate = codec == MovieCodecH264 || codec == MovieCodecHEVC;
    self.bitrateField.enabled = hasBitrate;
    self.bitrateField.stringValue = (hasBitrate && _recorder.bitrate > 0.0) ? [NSString stringWithFormat:@"%g", _recorder.bitrate] : @"";

    self.folderControl.URL = [NSURL fileURLWithPath:_recorder.folder isDirectory:YES];
    self.nameField.stringValue = _recorder.name;

    if (_recorder.oscPort > 0)
    {
        _portsLabel.stringValue = [NSString stringWithFormat:@"OSC on UDP port %ld \u00B7 OSCQuery on port %ld", (long)_recorder.oscPort, (long)_recorder.oscQueryPort];
    }
    else
    {
        _portsLabel.stringValue = @"OSC is not available";
    }
}

#pragma mark Actions

// A number typed by the user, who may use a comma for the decimals. 0 if it is not a number.
static double NumberTyped(NSString *string)
{
    NSScanner *scanner = [NSScanner scannerWithString:[string stringByReplacingOccurrencesOfString:@"," withString:@"."]];
    double value = 0.0;
    return ([scanner scanDouble:&value] && scanner.isAtEnd) ? value : 0.0;
}

- (void)codecChanged:(id)sender
{
    _recorder.codec = [MovieRecorderSettings nameForCodec:(MovieCodec)self.codecPopUp.indexOfSelectedItem];
}

- (void)sizePresetChanged:(id)sender
{
    NSInteger index = self.sizePopUp.indexOfSelectedItem;
    NSArray<NSArray<NSNumber *> *> *presets = SizePresets();
    if (index == 0)
    {
        _recorder.width = 0;
        _recorder.height = 0;
    }
    else if (index <= (NSInteger)presets.count)
    {
        _recorder.width = presets[index - 1][0].integerValue;
        _recorder.height = presets[index - 1][1].integerValue;
    }
    else if (_recorder.width == 0 || _recorder.height == 0)
    {
        // Custom: start from the size of the source, or failing that a common one, for the user to change
        _recorder.width = _recorder.sourceWidth > 0 ? _recorder.sourceWidth : 1920;
        _recorder.height = _recorder.sourceHeight > 0 ? _recorder.sourceHeight : 1080;
    }
    [self showSettings];
}

- (void)sizeFieldChanged:(id)sender
{
    _recorder.width = (NSInteger)NumberTyped(self.widthField.stringValue);
    _recorder.height = (NSInteger)NumberTyped(self.heightField.stringValue);
    [self showSettings];
}

- (void)rateChanged:(id)sender
{
    _recorder.fps = NumberTyped(self.rateComboBox.stringValue);
    [self showSettings];
}

- (void)bitrateChanged:(id)sender
{
    _recorder.bitrate = NumberTyped(self.bitrateField.stringValue);
    [self showSettings];
}

- (void)nameChanged:(id)sender
{
    _recorder.name = self.nameField.stringValue;
}

- (void)folderChanged:(id)sender
{
    NSURL *url = self.folderControl.URL;
    if (url.isFileURL)
    {
        _recorder.folder = url.path;
    }
}

- (void)pathControl:(NSPathControl *)pathControl willDisplayOpenPanel:(NSOpenPanel *)openPanel
{
    openPanel.canChooseDirectories = YES;
    openPanel.canChooseFiles = NO;
    openPanel.canCreateDirectories = YES;
    openPanel.prompt = @"Choose";
}

@end
