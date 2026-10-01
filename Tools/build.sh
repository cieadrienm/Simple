#!/bin/sh
# Builds the command line tools in this folder into build/tools, against a Debug build of the Syphon framework.
set -e
cd "$(dirname "$0")/.."
OUT="$PWD/build/tools"
xcodebuild -workspace Simple.xcworkspace -scheme Syphon -configuration Debug -derivedDataPath build/DerivedData build -quiet
FRAMEWORKS="$PWD/build/DerivedData/Build/Products/Debug"
mkdir -p "$OUT"
COMMON="-fobjc-arc -F $FRAMEWORKS -framework Syphon -framework Cocoa -framework Metal -Wl,-rpath,$FRAMEWORKS"
clang $COMMON -framework IOSurface Tools/syphon-probe.m -o "$OUT/syphon-probe"
clang $COMMON -framework OpenGL Tools/gl-server.m -o "$OUT/gl-server"
clang $COMMON -I Common -framework MetalKit -framework QuartzCore Tools/view-test.m Common/SimpleImageView.m -o "$OUT/view-test"
echo "built: $OUT"
