#!/bin/sh
# Builds the command line tools in this folder into build/tools, against a Debug build of the Syphon framework.
set -e
cd "$(dirname "$0")/.."
OUT="$PWD/build/tools"
xcodebuild -project Syphon-Framework/Syphon.xcodeproj -scheme Syphon -configuration Debug -derivedDataPath build/DerivedData build -quiet
FRAMEWORKS="$PWD/build/DerivedData/Build/Products/Debug"
mkdir -p "$OUT"
COMMON="-fobjc-arc -F $FRAMEWORKS -framework Syphon -framework Cocoa -framework Metal -Wl,-rpath,$FRAMEWORKS"
clang $COMMON -framework IOSurface Tools/syphon-probe.m -o "$OUT/syphon-probe"
clang $COMMON -framework OpenGL Tools/gl-server.m -o "$OUT/gl-server"
clang $COMMON -I Common -framework MetalKit -framework QuartzCore Tools/view-test.m Common/SimpleImageView.m -o "$OUT/view-test"
# NDI's headers are the package's own; the library is loaded at run time, so nothing is linked
NDI_HEADERS="ThirdParty/NDI/include"
[ -f "$NDI_HEADERS/Processing.NDI.Lib.h" ] || { echo "NDI headers not found in $NDI_HEADERS: Tools/ndi-send.m needs them (update NDI_HEADERS)" >&2; exit 1; }
clang -fobjc-arc -I "$NDI_HEADERS" -framework Foundation Tools/ndi-send.m -o "$OUT/ndi-send"
swiftc -O Tools/movie-info.swift -o "$OUT/movie-info"
echo "built: $OUT"
