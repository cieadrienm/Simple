// ndi-send <name> [width height fps] [--bgrx] [--tone [--rate hz] [--channels 1|2|4]]: an NDI sender of Simple Server's test pattern, to try the recorder's
// NDI sources. A grey background whose level pulses, a white bar which sweeps from left to right, and an orange marker
// in the top left corner. The first row of the buffer is the top of the picture (NDI pictures are not flipped).
// With --bgrx the frames are BGRX with a fourth byte of 0: a source without alpha, which must be recorded opaque.
// With --tone it sends sound beside the picture (planar 32-bit floats, 20 ms at a time, from a thread of its own): channel 1
// a 440 Hz sine, channel 2 880 Hz, channels 3 and 4 1320 and 1760 Hz, at -12 dB; and once each second a click, 5 ms of full
// scale on every channel instead of the tone, at the moment of one picture which is white all over (the flash), so that the
// step between sound and picture can be measured in a recording (movie-info --sync). Both threads are paced by the SDK's
// clock and count their seconds from the same start: second k's click begins at sample k * rate, its flash is frame
// round(k * fps), so the two are the same instant on that clock (the first second has neither).
// The library is loaded at run time, as the app does, and is not linked.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include "Processing.NDI.Lib.h"
#include "Processing.NDI.DynamicLoad.h"

static volatile sig_atomic_t stopRequested = 0;
static void requestStop(int signal) { (void)signal; stopRequested = 1; }

/// What the sound thread needs: the sender, the format, and the one start both threads count their seconds from.
typedef struct {
    const NDIlib_v5 *ndi;
    NDIlib_send_instance_t sender;
    int rate, channels;
} ToneJob;

static void *sendTone(void *argument)
{
    ToneJob *job = argument;
    const int piece = job->rate / 50; // 20 ms
    const int clickLength = job->rate * 5 / 1000;
    const double frequencies[4] = { 440, 880, 1320, 1760 };
    float *samples = malloc(sizeof(float) * piece * job->channels);
    NDIlib_audio_frame_v3_t frame = {
        .sample_rate = job->rate, .no_channels = job->channels, .no_samples = piece,
        .timecode = NDIlib_send_timecode_synthesize, .FourCC = NDIlib_FourCC_audio_type_FLTP,
        .p_data = (uint8_t *)samples, .channel_stride_in_bytes = piece * (int)sizeof(float),
    };
    for (unsigned long long first = 0; !stopRequested; first += piece) {
        for (int c = 0; c < job->channels; c++) {
            for (int i = 0; i < piece; i++) {
                unsigned long long index = first + i;
                // The first clickLength samples of each second are the click
                // (not the very first second's: the receiver may join a little late)
                BOOL click = index >= (unsigned long long)job->rate && (index % (unsigned long long)job->rate) < (unsigned long long)clickLength;
                samples[c * piece + i] = click ? 1.0f
                    : 0.25f * (float)sin(2 * M_PI * frequencies[c] * (double)(index % (unsigned long long)job->rate) / job->rate);
            }
        }
        job->ndi->send_send_audio_v3(job->sender, &frame); // paced by the SDK's audio clock
    }
    free(samples);
    return NULL;
}

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
    BOOL bgrx = NO, tone = NO;
    int rate = 48000, channels = 2;
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bgrx") == 0) bgrx = YES;
        else if (strcmp(argv[i], "--tone") == 0) tone = YES;
        else if (strcmp(argv[i], "--rate") == 0 && i + 1 < argc) rate = atoi(argv[++i]);
        else if (strcmp(argv[i], "--channels") == 0 && i + 1 < argc) channels = atoi(argv[++i]);
        else [arguments addObject:@(argv[i])];
    }
    if ((arguments.count != 1 && arguments.count != 4) || rate < 8000 || rate > 192000 || rate % 50 != 0
        || (channels != 1 && channels != 2 && channels != 4)) {
        fprintf(stderr, "usage: ndi-send <name> [width height fps] [--bgrx] [--tone [--rate <hz, a multiple of 50>] [--channels <1|2|4>]]\n");
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
    NDIlib_send_create_t settings = { .p_ndi_name = name, .p_groups = NULL, .clock_video = true, .clock_audio = tone };
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
    printf("ndi-send: sending \"%s\" %dx%d at %g fps", name, width, height, fps);
    if (tone) printf(", sound %d Hz %d channels", rate, channels);
    printf("\n");
    fflush(stdout);

    ToneJob job = { .ndi = ndi, .sender = sender, .rate = rate, .channels = channels };
    pthread_t toneThread;
    if (tone && pthread_create(&toneThread, NULL, sendTone, &job) != 0) {
        fprintf(stderr, "ndi-send: cannot start the sound thread\n");
        ndi->send_destroy(sender);
        return 1;
    }

    int marker = (int)(width * 0.07);
    if (marker < 4) marker = 4;
    int barWidth = width / 40 > 2 ? width / 40 : 2;
    for (unsigned long n = 0; !stopRequested; n++) {
        double seconds = n / fps;
        uint8_t grey = (uint8_t)(102 + 40 * sin(seconds * 2 * M_PI / 4));
        int barX = (int)(fmod(seconds / 5, 1.0) * (width - barWidth));
        uint8_t alpha = bgrx ? 0 : 255;
        // Frame round(k * fps) is the picture of second k, where the click of second k begins
        double k = floor(n / fps + 0.5);
        BOOL flash = tone && k >= 1 && (unsigned long)floor(k * fps + 0.5) == n;
        if (flash) {
            memset(pixels, 255, stride * height);
        } else for (int y = 0; y < height; y++) {
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
    if (tone) pthread_join(toneThread, NULL);
    ndi->send_destroy(sender);
    ndi->destroy();
    free(pixels);
} return 0; }
