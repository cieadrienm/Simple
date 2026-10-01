// gl-server: a minimal OpenGL Syphon server, to check that we treat frames from OpenGL applications correctly.
// Publishes a grey frame with an orange marker at the OpenGL origin (the bottom left of the picture) for six seconds.
#define GL_SILENCE_DEPRECATION 1
#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <Syphon/Syphon.h>
int main(void) { @autoreleasepool {
    CGLPixelFormatAttribute attrs[] = { kCGLPFAAccelerated, kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, 0 };
    CGLPixelFormatObj pf; GLint n; CGLChoosePixelFormat(attrs, &pf, &n);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    SyphonOpenGLServer *server = [[SyphonOpenGLServer alloc] initWithName:@"gltest" context:ctx options:nil];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:6];
    while ([end timeIntervalSinceNow] > 0) {
        [server bindToDrawFrameOfSize:NSMakeSize(640, 480)];
        glDisable(GL_SCISSOR_TEST); glClearColor(0.4, 0.4, 0.4, 1); glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_SCISSOR_TEST); glScissor(0, 0, 64, 48); glClearColor(1, 0.5, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
        [server unbindAndPublish];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0 / 30]];
    }
    [server stop];
} return 0; }
