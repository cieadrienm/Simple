#!/bin/sh
# Builds Simple Client and Simple Server for release into build/, with simple-recorder-mcp inside Simple Client,
# and signs them.
#
#   Scripts/bundle.sh             build/Simple Client.app and build/Simple Server.app
#   INSTALL=1 Scripts/bundle.sh   also copies them to /Applications
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/bundle.sh   signs with that identity ("-" for ad hoc)
set -e
cd "$(dirname "$0")/.."

DERIVED="build/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"

for SCHEME in "Simple Client" "Simple Server"; do
    xcodebuild -workspace Simple.xcworkspace -scheme "$SCHEME" -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" build -quiet
done
swift build -c release --arch arm64 --arch x86_64 --product simple-recorder-mcp

for APP in "Simple Client" "Simple Server"; do
    rm -rf "build/$APP.app"
    ditto "$PRODUCTS/$APP.app" "build/$APP.app"
done
cp .build/apple/Products/Release/simple-recorder-mcp "build/Simple Client.app/Contents/MacOS/"

# Signing. A real identity keeps the apps' identity stable across rebuilds, so macOS remembers their permissions
# (Local Network, for OSC and OSCQuery). Without one they are signed ad hoc, and macOS asks again after each build.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
sign() {
    codesign --force --timestamp=none --sign "$1" "build/Simple Client.app/Contents/Frameworks/Syphon.framework/Versions/A" \
        "build/Simple Client.app/Contents/MacOS/simple-recorder-mcp" "build/Simple Client.app" \
        "build/Simple Server.app/Contents/Frameworks/Syphon.framework/Versions/A" "build/Simple Server.app"
}
if ! sign "$SIGN_IDENTITY" 2>build/codesign.log; then
    echo "warning: signing with '$SIGN_IDENTITY' failed ($(tail -1 build/codesign.log)); signing ad hoc instead" >&2
    SIGN_IDENTITY="-"
    sign "-"
fi
echo "signed: $SIGN_IDENTITY" >&2

if [ "${INSTALL:-0}" = "1" ]; then
    for APP in "Simple Client" "Simple Server"; do
        rm -rf "/Applications/$APP.app"
        ditto "build/$APP.app" "/Applications/$APP.app"
    done
    echo "installed in /Applications" >&2
fi
echo "built: build/Simple Client.app, build/Simple Server.app"
