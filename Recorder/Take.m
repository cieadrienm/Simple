/*
 Take.m
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

#import "Take.h"

@interface TakeMovie ()
@property (readwrite, copy) NSString *sourceTitle;
@property (readwrite) NSURL *url;
@property (readwrite, nullable) NSError *error;
@property (strong) MovieRecorder *recorder;
@end

@implementation TakeMovie

- (NSUInteger)framesWritten
{
    return self.recorder.framesWritten;
}

- (NSUInteger)framesDropped
{
    return self.recorder.framesDropped;
}

@end

// A name for a file: it cannot be a path, nor a hidden file
static NSString *FileName(NSString *name)
{
    NSString *safe = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]] componentsJoinedByString:@"-"];
    if ([safe hasPrefix:@"."])
    {
        safe = [@"-" stringByAppendingString:[safe substringFromIndex:1]];
    }
    return safe;
}

@implementation Take {
    id<MTLDevice> _device;
    // Recorders are kept from one take to the next: making one compiles its shaders
    NSMutableArray<MovieRecorder *> *_recorders;
    // Main thread, like movies, except in appendTexture: which reads the array it was given at the start
    NSArray<TakeMovie *> *_movies;
    BOOL _recording;
    BOOL _finishing;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self)
    {
        _device = device;
        _recorders = [NSMutableArray array];
        _movies = @[];
    }
    return self;
}

+ (NSArray<NSURL *> *)urlsForName:(NSString *)name sourceTitles:(NSArray<NSString *> *)titles inFolder:(NSURL *)folder
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *base = FileName(name);
    for (NSInteger number = 1; ; number++)
    {
        NSString *numbered = number == 1 ? base : [NSString stringWithFormat:@"%@ %ld", base, (long)number];
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        BOOL taken = NO;
        for (NSString *title in titles)
        {
            NSString *file = titles.count == 1 ? numbered : [NSString stringWithFormat:@"%@ \u2014 %@", numbered, FileName(title)];
            NSURL *url = [folder URLByAppendingPathComponent:[file stringByAppendingPathExtension:@"mov"]];
            taken = taken || [fileManager fileExistsAtPath:url.path];
            [urls addObject:url];
        }
        if (!taken)
        {
            return urls;
        }
    }
}

- (BOOL)isRecording
{
    @synchronized (self)
    {
        return _recording;
    }
}

- (NSArray<TakeMovie *> *)movies
{
    @synchronized (self)
    {
        return _movies;
    }
}

- (NSUInteger)framesPending
{
    NSUInteger pending = 0;
    for (TakeMovie *movie in self.movies)
    {
        pending += movie.recorder.framesPending;
    }
    return pending;
}

static NSError *TakeError(NSString *description)
{
    return [NSError errorWithDomain:MovieRecorderErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (BOOL)startWithSourceTitles:(NSArray<NSString *> *)titles
                        sizes:(NSArray *)sizes
                         name:(NSString *)name
                       folder:(NSURL *)folder
                     settings:(MovieRecorderSettings *)settings
                       atTime:(NSTimeInterval)time
                        error:(NSError **)error
{
    NSString *problem = nil;
    BOOL isFolder = NO;
    @synchronized (self)
    {
        if (_recording)
        {
            problem = @"A recording is already in progress";
        }
        else if (_finishing)
        {
            problem = @"The previous movies are still being finished";
        }
    }
    if (problem == nil && titles.count == 0)
    {
        problem = @"No source is selected";
    }
    if (problem == nil && (![[NSFileManager defaultManager] fileExistsAtPath:folder.path isDirectory:&isFolder] || !isFolder))
    {
        problem = [NSString stringWithFormat:@"The folder \u201C%@\u201D does not exist", folder.path];
    }
    if (problem)
    {
        if (error)
        {
            *error = TakeError(problem);
        }
        return NO;
    }

    while (_recorders.count < titles.count)
    {
        MovieRecorder *recorder = [[MovieRecorder alloc] initWithDevice:_device];
        if (recorder == nil)
        {
            if (error)
            {
                *error = TakeError(@"Movies cannot be written on this Mac: Metal is not available");
            }
            return NO;
        }
        [_recorders addObject:recorder];
    }

    NSArray<NSURL *> *urls = [Take urlsForName:name sourceTitles:titles inFolder:folder];
    NSMutableArray<TakeMovie *> *movies = [NSMutableArray array];
    __weak Take *weakSelf = self;
    for (NSUInteger index = 0; index < titles.count; index++)
    {
        TakeMovie *movie = [[TakeMovie alloc] init];
        movie.sourceTitle = titles[index];
        movie.url = urls[index];
        movie.recorder = _recorders[index];

        // Each movie is the size of its source. Known now, the movie is ready for its first frame; if not, it takes
        // the size of the first frame it receives.
        MovieRecorderSettings *own = [settings copy];
        id size = index < sizes.count ? sizes[index] : [NSNull null];
        own.width = [size isKindOfClass:[NSValue class]] ? (NSInteger)[size sizeValue].width : 0;
        own.height = [size isKindOfClass:[NSValue class]] ? (NSInteger)[size sizeValue].height : 0;

        __weak TakeMovie *weakMovie = movie;
        movie.recorder.failureHandler = ^(NSError *failure) {
            weakMovie.error = failure;
            Take *take = weakSelf;
            if (take.movieFailureHandler)
            {
                take.movieFailureHandler(index, failure);
            }
        };
        NSError *startError = nil;
        if (![movie.recorder startWritingToURL:movie.url settings:own startTime:time error:&startError])
        {
            // Nothing of this take stays
            for (TakeMovie *started in movies)
            {
                [started.recorder finishAtTime:time completionHandler:^(NSError *ignored) {}];
            }
            if (error)
            {
                *error = startError;
            }
            return NO;
        }
        [movies addObject:movie];
    }

    @synchronized (self)
    {
        _movies = [movies copy];
        _recording = YES;
    }
    return YES;
}

- (void)appendTexture:(id<MTLTexture>)texture flipped:(BOOL)flipped fromSourceAtIndex:(NSUInteger)index atTime:(NSTimeInterval)time
{
    NSArray<TakeMovie *> *movies;
    @synchronized (self)
    {
        if (!_recording)
        {
            return;
        }
        movies = _movies;
    }
    if (index < movies.count)
    {
        [movies[index].recorder appendTexture:texture flipped:flipped atTime:time];
    }
}

- (void)finishAtTime:(NSTimeInterval)time completionHandler:(void (^)(NSError * _Nullable error))handler
{
    NSArray<TakeMovie *> *movies;
    @synchronized (self)
    {
        if (!_recording)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(TakeError(@"There is no recording in progress"));
            });
            return;
        }
        _recording = NO;
        _finishing = YES;
        movies = _movies;
    }

    dispatch_group_t finished = dispatch_group_create();
    for (TakeMovie *movie in movies)
    {
        if (movie.error)
        {
            // It failed during the take, and has stopped
            continue;
        }
        dispatch_group_enter(finished);
        [movie.recorder finishAtTime:time completionHandler:^(NSError *error) {
            // A movie which received no frame has no file: that is not a failure of its own
            if (error && movie.recorder.framesWritten > 0)
            {
                movie.error = error;
            }
            dispatch_group_leave(finished);
        }];
    }
    dispatch_group_notify(finished, dispatch_get_main_queue(), ^{
        NSUInteger frames = 0;
        for (TakeMovie *movie in movies)
        {
            frames += movie.recorder.framesWritten;
        }
        @synchronized (self)
        {
            self->_finishing = NO;
        }
        handler(frames > 0 ? nil : TakeError(@"No frame was received, so no movie was written"));
    });
}

@end
