// ndi-send <name> [width height fps] [--bgrx]: an NDI sender of Simple Server's test pattern, to try the recorder's
// NDI sources. A grey background whose level pulses, a white bar which sweeps from left to right, and an orange marker
// in the top left corner. The first row of the buffer is the top of the picture (NDI pictures are not flipped).
// With --bgrx the frames are BGRX with a fourth byte of 0: a source without alpha, which must be recorded opaque.
// The library is loaded at run time, as the app does, and is not linked.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "Processing.NDI.Lib.h"
#include "Processing.NDI.DynamicLoad.h"

static volatile sig_atomic_t stopRequested = 0;
static void requestStop(int signal) { (void)signal; stopRequested = 1; }

static const NDIlib_v5 *loadLibrary(void)
{
    const char *chosen = getenv("SIMPLE_NDI_LIBRARY");
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (chosen && *chosen) {
        [paths addObject:@(chosen)];
    } else {
        const char *runtime = getenv("NDI_RUNTIME_DIR_V6");
        if (runtime && *runtime)
            [paths addObject:[@(runtime) stringByAppendingPathComponent:@"libndi.dylib"]];
        [paths addObject:@"/usr/local/lib/libndi.dylib"];
        [paths addObject:@"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"];
    }
    for (NSString *path in paths) {
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) continue;
        const NDIlib_v5 *(*load)(void) = (const NDIlib_v5 *(*)(void))dlsym(handle, "NDIlib_v5_load");
        const NDIlib_v5 *functions = load ? load() : NULL;
        if (functions) return functions;
    }
    fprintf(stderr, "ndi-send: libndi.dylib was not found in %s\n", [[paths componentsJoinedByString:@", "] UTF8String]);
    return NULL;
}

int main(int argc, char **argv) { @autoreleasepool {
    BOOL bgrx = NO;
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bgrx") == 0) bgrx = YES;
        else [arguments addObject:@(argv[i])];
    }
    if (arguments.count != 1 && arguments.count != 4) {
        fprintf(stderr, "usage: ndi-send <name> [width height fps] [--bgrx]\n");
        return 2;
    }
    int width = 1280, height = 720;
    double fps = 30;
    if (arguments.count == 4) {
        width = arguments[1].intValue; height = arguments[2].intValue; fps = arguments[3].doubleValue;
        if (width < 16 || height < 16 || fps <= 0) {
            fprintf(stderr, "ndi-send: the size must be at least 16 x 16 and the rate above 0\n");
            return 2;
        }
    }

    const NDIlib_v5 *ndi = loadLibrary();
    if (!ndi) return 1;
    if (!ndi->initialize()) { fprintf(stderr, "ndi-send: the NDI library cannot run on this machine\n"); return 1; }

    const char *name = arguments[0].UTF8String;
    NDIlib_send_create_t settings = { .p_ndi_name = name, .p_groups = NULL, .clock_video = true, .clock_audio = false };
    NDIlib_send_instance_t sender = ndi->send_create(&settings);
    if (!sender) { fprintf(stderr, "ndi-send: cannot create the sender\n"); return 1; }

    signal(SIGTERM, requestStop);
    signal(SIGINT, requestStop);

    size_t stride = (size_t)width * 4;
    uint8_t *pixels = malloc(stride * height);
    NDIlib_video_frame_v2_t frame = {
        .xres = width, .yres = height,
        .FourCC = bgrx ? NDIlib_FourCC_video_type_BGRX : NDIlib_FourCC_video_type_BGRA,
        .frame_rate_N = (int)(fps * 1000 + 0.5), .frame_rate_D = 1000,
        .picture_aspect_ratio = (float)width / height,
        .frame_format_type = NDIlib_frame_format_type_progressive,
        .timecode = NDIlib_send_timecode_synthesize,
        .p_data = pixels, .line_stride_in_bytes = (int)stride,
    };
    printf("ndi-send: sending \"%s\" %dx%d at %g fps\n", name, width, height, fps);
    fflush(stdout);

    int marker = (int)(width * 0.07);
    if (marker < 4) marker = 4;
    int barWidth = width / 40 > 2 ? width / 40 : 2;
    for (unsigned long n = 0; !stopRequested; n++) {
        double seconds = n / fps;
        uint8_t grey = (uint8_t)(102 + 40 * sin(seconds * 2 * M_PI / 4));
        int barX = (int)(fmod(seconds / 5, 1.0) * (width - barWidth));
        uint8_t alpha = bgrx ? 0 : 255;
        for (int y = 0; y < height; y++) {
            uint8_t *row = pixels + y * stride;
            for (int x = 0; x < width; x++) {
                uint8_t b = grey, g = grey, r = grey;
                if (x >= barX && x < barX + barWidth) b = g = r = 255;
                if (x < marker && y < marker) { b = 0; g = 128; r = 255; }
                row[x * 4] = b; row[x * 4 + 1] = g; row[x * 4 + 2] = r; row[x * 4 + 3] = alpha;
            }
        }
        ndi->send_send_video_v2(sender, &frame);
    }
    ndi->send_destroy(sender);
    ndi->destroy();
    free(pixels);
} return 0; }
