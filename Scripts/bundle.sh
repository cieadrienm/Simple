#!/bin/sh
# Builds Simple Recorder and Simple Server for release into build/, and signs them.
#
#   Scripts/bundle.sh             build/Simple Recorder.app and build/Simple Server.app
#   INSTALL=1 Scripts/bundle.sh   also copies them to /Applications
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/bundle.sh   signs with that identity ("-" for ad hoc)
#   NDI_LIBRARY=<path to libndi.dylib> Scripts/bundle.sh   puts that NDI library in the app (default: the NDI SDK's)
#
# Simple Recorder is a SwiftPM executable (the SwiftUI app in App/, the core in Recorder/), put in a bundle here
# with Syphon's framework and the MCP tool. Simple Server is built from its Xcode project.
set -e
cd "$(dirname "$0")/.."
# The version shown by the Finder, About and /status/version: bump it here, and only here (CHANGELOG.md says what
# changed; a release is tagged vX.Y.Z). The build number counts commits.
VERSION="1.1.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

Scripts/syphon.sh
swift build -c release --arch arm64 --arch x86_64 --product SimpleRecorder
swift build -c release --arch arm64 --arch x86_64 --product simple-recorder-mcp
PRODUCTS=".build/apple/Products/Release"

APP="build/Simple Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamped in the bundle's copy only: Resources/Info.plist keeps the placeholders
sed -i '' -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" "$APP/Contents/Info.plist"
if grep -q '@VERSION@\|@BUILD@' "$APP/Contents/Info.plist"; then
    echo "error: the version was not stamped into the app's Info.plist" >&2
    exit 1
fi
cp Resources/icon.icns "$APP/Contents/Resources/"
cp "$PRODUCTS/SimpleRecorder" "$APP/Contents/MacOS/Simple Recorder"
cp "$PRODUCTS/simple-recorder-mcp" "$APP/Contents/MacOS/"
ditto build/Syphon.xcframework/macos-arm64_x86_64/Syphon.framework "$APP/Contents/Frameworks/Syphon.framework"
# SwiftPM looks for Syphon beside the executable: in a bundle it is in Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Simple Recorder"

# NDI's library goes in the app when we have it; without it the app works, and does not list NDI sources
NDI_LIBRARY="${NDI_LIBRARY:-/Library/NDI SDK for Apple/lib/macOS/libndi.dylib}"
HAS_NDI=0
if [ -f "$NDI_LIBRARY" ]; then
    cp "$NDI_LIBRARY" "$APP/Contents/Frameworks/libndi.dylib"
    HAS_NDI=1
else
    echo "NDI's library was not found: the app is built without it" >&2
fi

DERIVED="build/DerivedData"
xcodebuild -workspace Simple.xcworkspace -scheme "Simple Server" -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" build -quiet
rm -rf "build/Simple Server.app"
ditto "$DERIVED/Build/Products/Release/Simple Server.app" "build/Simple Server.app"

# Signing. A real identity keeps the apps' identity stable across rebuilds, so macOS remembers their permissions
# (Local Network, for OSC and OSCQuery). Without one they are signed ad hoc, and macOS asks again after each build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
sign() {
    # The library is signed before the app, which seals it
    if [ "$HAS_NDI" = "1" ]; then
        codesign --force --timestamp=none --sign "$1" "$APP/Contents/Frameworks/libndi.dylib"
    fi
    codesign --force --timestamp=none --sign "$1" "$APP/Contents/Frameworks/Syphon.framework/Versions/A" \
        "$APP/Contents/MacOS/simple-recorder-mcp" "$APP" \
        "build/Simple Server.app/Contents/Frameworks/Syphon.framework/Versions/A" "build/Simple Server.app"
}
if ! sign "$SIGN_IDENTITY" 2>build/codesign.log; then
    echo "warning: signing with '$SIGN_IDENTITY' failed ($(tail -1 build/codesign.log)); signing ad hoc instead" >&2
    SIGN_IDENTITY="-"
    sign "-"
fi
codesign --verify --deep --strict "$APP"
echo "signed: $SIGN_IDENTITY" >&2

if [ "${INSTALL:-0}" = "1" ]; then
    for NAME in "Simple Recorder" "Simple Server"; do
        rm -rf "/Applications/$NAME.app"
        ditto "build/$NAME.app" "/Applications/$NAME.app"
    done
    echo "installed in /Applications" >&2
fi
echo "built: $APP, build/Simple Server.app"
