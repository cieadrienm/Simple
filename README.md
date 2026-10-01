Simple
======

Simple Client and Simple Server demo and testbed applications for [Syphon](https://github.com/Syphon/Syphon-Framework).

- **Simple Server** publishes an animated test pattern (a pulsing background, a bar which sweeps across the frame and a marker in the top left corner). Resize its window to change the size of the frames it publishes.
- **Simple Client** displays the frames of any Syphon server.

Both render with Metal (`SyphonMetalServer` and `SyphonMetalClient`).

Building
--------

Requires Xcode 16 or later. The apps run on macOS 13 or later, on Apple silicon and Intel.

The Syphon framework is a submodule, so clone with `--recursive` or fetch it afterwards:

    git submodule update --init

Then open `Simple.xcworkspace`, or build from the command line:

    xcodebuild -workspace Simple.xcworkspace -scheme "Simple Client" -configuration Release -destination 'generic/platform=macOS' build
    xcodebuild -workspace Simple.xcworkspace -scheme "Simple Server" -configuration Release -destination 'generic/platform=macOS' build

Checking without looking at the screen
--------------------------------------

`Tools/build.sh` builds three command line tools into `build/tools`:

- `syphon-probe` lists the Syphon servers which are running, or saves a frame from one of them as a PNG and prints its size and frame rate
- `view-test` saves what `SimpleImageView` draws for a frame from Simple Server
- `gl-server` is a minimal OpenGL Syphon server, to compare with frames from Metal
