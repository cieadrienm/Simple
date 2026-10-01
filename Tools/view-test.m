// view-test <file.png>: draws a frame from a running Simple Server through SimpleImageView into an offscreen texture
// and saves it, to check what the view shows without looking at the screen.
#import <Cocoa/Cocoa.h>
#import <Syphon/Syphon.h>
#import "SimpleImageView.h"
@interface TestView : SimpleImageView
@property (strong) id<MTLTexture> target;
@end
@implementation TestView
- (MTLRenderPassDescriptor *)currentRenderPassDescriptor {
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = self.target;
    p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].clearColor = self.clearColor;
    p.colorAttachments[0].storeAction = MTLStoreActionStore;
    return p;
}
- (CGSize)drawableSize { return CGSizeMake(self.target.width, self.target.height); }
@end
int main(int argc, const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    TestView *view = [[TestView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    win.contentView = view;
    [view awakeFromNib];
    view.imageIsFlipped = YES;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:400 height:400 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
    view.target = [view.device newTextureWithDescriptor:d];
    NSDictionary *found = nil;
    for (int i = 0; i < 30 && !found; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        for (NSDictionary *s in [SyphonServerDirectory sharedDirectory].servers)
            if ([s[SyphonServerDescriptionAppNameKey] isEqualToString:@"Simple Server"]) found = s;
    }
    SyphonMetalClient *client = [[SyphonMetalClient alloc] initWithServerDescription:found device:view.device options:nil newFrameHandler:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    view.image = [client newFrameImage];
    printf("image %lux%lu error=%s\n", view.image.width, view.image.height, view.error.description.UTF8String);
    [view drawRect:view.bounds];
    [NSThread sleepForTimeInterval:0.5];
    NSMutableData *px = [NSMutableData dataWithLength:400 * 400 * 4];
    [view.target getBytes:px.mutableBytes bytesPerRow:1600 fromRegion:MTLRegionMake2D(0, 0, 400, 400) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, 400, 400, 8, 1600, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:CGBitmapContextCreateImage(ctx)];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
} return 0; }
