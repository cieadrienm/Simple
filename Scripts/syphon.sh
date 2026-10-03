#!/bin/sh
# Builds the Syphon framework of the submodule as build/Syphon.xcframework, which Package.swift needs.
# Does nothing if it is already there and the submodule has not moved since.
set -e
cd "$(dirname "$0")/.."

[ -f Syphon-Framework/Syphon.xcodeproj/project.pbxproj ] || git submodule update --init

REVISION="$(git -C Syphon-Framework rev-parse HEAD)"
STAMP="build/Syphon.xcframework/revision"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$REVISION" ]; then
    exit 0
fi

DERIVED="build/DerivedData"
xcodebuild -project Syphon-Framework/Syphon.xcodeproj -scheme Syphon -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" build -quiet
rm -rf build/Syphon.xcframework
xcodebuild -create-xcframework -framework "$DERIVED/Build/Products/Release/Syphon.framework" \
    -output build/Syphon.xcframework > /dev/null
echo "$REVISION" > "$STAMP"
echo "built: build/Syphon.xcframework"
