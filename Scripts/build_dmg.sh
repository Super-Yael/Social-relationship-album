#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/个人相册.app"
DMG_PATH="$DIST_DIR/个人相册-本机版.dmg"
INFO_PLIST="$PROJECT_DIR/Packaging/Info.plist"

mkdir -p "$DIST_DIR"

swift build --package-path "$PROJECT_DIR" -c release --arch arm64
BIN_DIR=$(swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --show-bin-path)
EXECUTABLE="$BIN_DIR/PersonalAlbum"

if [[ ! -x "$EXECUTABLE" ]]; then
    print -u2 "找不到 Release 可执行文件：$EXECUTABLE"
    exit 1
fi

if [[ "$APP_BUNDLE" != "$PROJECT_DIR"/dist/* || "$DMG_PATH" != "$PROJECT_DIR"/dist/* ]]; then
    print -u2 "拒绝清理非 dist 目标。"
    exit 1
fi

rm -rf "$APP_BUNDLE"
rm -f "$DMG_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/PersonalAlbum"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
chmod 755 "$APP_BUNDLE/Contents/MacOS/PersonalAlbum"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/personal-album-dmg.XXXXXX")
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT INT TERM

cp -R "$APP_BUNDLE" "$STAGING_DIR/个人相册.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "个人相册" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

codesign --verify --deep --strict "$APP_BUNDLE"
print "APP=$APP_BUNDLE"
print "DMG=$DMG_PATH"
