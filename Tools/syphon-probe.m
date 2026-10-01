// syphon-probe: looks at Syphon servers without a window, for checking the apps from a script.
//
//   syphon-probe                    lists the servers which are running
//   syphon-probe <app> <file.png>   receives frames from the server of that application for two seconds, prints
//                                   their size and rate, and saves the last one. Rows are written in memory order:
//                                   a Syphon frame has the bottom of its picture in the first row, so the PNG is
//                                   upside down.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <Syphon/Syphon.h>
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc < 3) {
        [SyphonServerDirectory sharedDirectory];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        for (NSDictionary *d in [SyphonServerDirectory sharedDirectory].servers)
            printf("app='%s' name='%s'\n", [d[SyphonServerDescriptionAppNameKey] UTF8String], [d[SyphonServerDescriptionNameKey] UTF8String]);
        return 0;
    }
    NSString *want = @(argv[1]); NSString *out = @(argv[2]);
    NSDictionary *found = nil;
    for (int i = 0; i < 30 && !found; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        for (NSDictionary *d in [SyphonServerDirectory sharedDirectory].servers)
            if ([d[SyphonServerDescriptionAppNameKey] isEqualToString:want]) found = d;
    }
    if (!found) { fprintf(stderr, "no server named %s\n", argv[1]); return 1; }
    __block int frames = 0;
    SyphonMetalClient *client = [[SyphonMetalClient alloc] initWithServerDescription:found device:MTLCreateSystemDefaultDevice() options:nil newFrameHandler:^(SyphonMetalClient *c) { frames++; }];
    NSDate *start = [NSDate date];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
    double fps = frames / -[start timeIntervalSinceNow];
    id<MTLTexture> t = [client newFrameImage];
    if (!t) { fprintf(stderr, "no frame\n"); return 2; }
    IOSurfaceRef s = t.iosurface;
    IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
    size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), rb = IOSurfaceGetBytesPerRow(s);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(IOSurfaceGetBaseAddress(s), w, h, 8, rb, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
    IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    printf("%zux%zu, %.1f fps, wrote %s\n", w, h, fps, argv[2]);
    [client stop];
} return 0; }
