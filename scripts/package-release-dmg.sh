#!/bin/zsh
# Build a self-contained, native-architecture drag-to-Applications installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 'Version must have the form 1.1.0'
    exit 1
fi
ARCH="$(uname -m)"
case "$ARCH" in
    arm64) RUST_TARGET=aarch64-apple-darwin ;;
    x86_64) RUST_TARGET=x86_64-apple-darwin ;;
    *) print -u2 "Unsupported architecture: $ARCH"; exit 1 ;;
esac
OUTPUT_DIR="$PROJECT_DIR/release"
NAME="Snake-$VERSION-macos-$ARCH"
DMG="$OUTPUT_DIR/$NAME.dmg"
if [[ -e "$DMG" || -e "$DMG.sha256" ]]; then
    print -u2 "Output already exists; move the previous release before rebuilding: $DMG"
    exit 1
fi
mkdir -p "$OUTPUT_DIR" "$PROJECT_DIR/.build"
STAGING="$(mktemp -d "$PROJECT_DIR/.build/release-stage.XXXXXX")"
PAYLOAD="$STAGING/installer"
APP="$PAYLOAD/Snake.app"
MACOS="$APP/Contents/MacOS"
FRAMEWORKS="$APP/Contents/Frameworks"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$FRAMEWORKS" "$RESOURCES"

"$SCRIPT_DIR/generate-core-bindings.sh"
swift build -c release --disable-sandbox --product Snake
swift build -c release --disable-sandbox --product SnakeMountHelper
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
cp "$BIN_DIR/Snake" "$BIN_DIR/SnakeMountHelper" "$MACOS/"
cp Rust/snake_core/target/release/libsnake_core.dylib "$FRAMEWORKS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$RESOURCES/"
# Localized .lproj tables must land directly in Contents/Resources so
# Bundle.main (used by SwiftUI's LocalizedStringKey and L10n) resolves them.
for lproj in Resources/Localization/*.lproj; do
    ditto "$lproj" "$RESOURCES/${lproj:t}"
done
ditto "$BIN_DIR/SwiftTerm_SwiftTerm.bundle" "$RESOURCES/SwiftTerm_SwiftTerm.bundle"
python3 "$SCRIPT_DIR/collect-release-licenses.py" "$RESOURCES/Licenses" --target "$RUST_TARGET"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
if [[ -n "${SNAKE_BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "$SNAKE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
swift "$SCRIPT_DIR/verify-release-resources.swift" "$APP"
CORE_LINK="$(otool -L "$MACOS/Snake" | awk '/libsnake_core.dylib/{print $1; exit}')"
[[ -n "$CORE_LINK" ]]
install_name_tool -change "$CORE_LINK" '@rpath/libsnake_core.dylib' "$MACOS/Snake"
install_name_tool -id '@rpath/libsnake_core.dylib' "$FRAMEWORKS/libsnake_core.dylib"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS/Snake"
# No external/Homebrew dynamic libraries may leak into the release.
for binary in "$MACOS/Snake" "$MACOS/SnakeMountHelper" "$FRAMEWORKS/libsnake_core.dylib"; do
    lipo "$binary" -verify_arch "$ARCH"
    otool -L "$binary" | tail -n +2 | awk '{print $1}' | while read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
            *) print -u2 "Unbundled dependency: $dependency"; exit 1 ;;
        esac
    done
done

# No certificate is needed for the default local/test installer.
# Developer ID signing is optional; notarization is a separate release gate.
IDENTITY="${SNAKE_SIGNING_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != '-' ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$FRAMEWORKS/libsnake_core.dylib"
codesign "${SIGN_ARGS[@]}" "$MACOS/SnakeMountHelper"
codesign "${SIGN_ARGS[@]}" "$MACOS/Snake"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
ln -s /Applications "$PAYLOAD/Applications"
cp "$PROJECT_DIR/docs/INSTALL.md" "$PAYLOAD/安装说明.md"
if [[ -f "$PROJECT_DIR/docs/en/INSTALL.md" ]]; then
    cp "$PROJECT_DIR/docs/en/INSTALL.md" "$PAYLOAD/Installation Guide.md"
fi
hdiutil create -volname "Snake $VERSION" -srcfolder "$PAYLOAD" -fs HFS+ -format UDZO "$STAGING/$NAME.dmg"
hdiutil verify "$STAGING/$NAME.dmg"
if [[ "$IDENTITY" != '-' ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$STAGING/$NAME.dmg"
fi
mv "$STAGING/$NAME.dmg" "$DMG"
(cd "$OUTPUT_DIR" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
printf 'Installer: %s\nStaged app: %s\nSigning: %s (not notarized by this script)\n' "$DMG" "$APP" "$IDENTITY"
