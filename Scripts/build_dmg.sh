#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/个人相册.app"
DMG_PATH="$DIST_DIR/个人相册-本机版.dmg"
INFO_PLIST="$PROJECT_DIR/Packaging/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/Packaging/PersonalAlbum.entitlements"
PRIVACY_MANIFEST="$PROJECT_DIR/Packaging/PrivacyInfo.xcprivacy"
LEGACY_APP_ICON="$PROJECT_DIR/Packaging/AppIcon.icns"
COMPOSED_APP_ICON="$PROJECT_DIR/Packaging/AppIcon.icon"
SIGNING_IDENTITY=${CODESIGN_IDENTITY:--}
NOTARIZATION_PROFILE=${NOTARYTOOL_PROFILE:-}

mkdir -p "$DIST_DIR"

swift build --package-path "$PROJECT_DIR" -c release --arch arm64
BIN_DIR=$(swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --show-bin-path)
EXECUTABLE="$BIN_DIR/PersonalAlbum"

if [[ ! -x "$EXECUTABLE" ]]; then
    print -u2 "找不到 Release 可执行文件：$EXECUTABLE"
    exit 1
fi

if [[ ! -f "$LEGACY_APP_ICON" ]]; then
    print -u2 "找不到兼容图标：$LEGACY_APP_ICON"
    exit 1
fi

if [[ ! -d "$COMPOSED_APP_ICON" ]]; then
    print -u2 "找不到 Icon Composer 图标：$COMPOSED_APP_ICON"
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    print -u2 "找不到沙盒权限配置：$ENTITLEMENTS"
    exit 1
fi

if [[ ! -f "$PRIVACY_MANIFEST" ]]; then
    print -u2 "找不到隐私清单：$PRIVACY_MANIFEST"
    exit 1
fi

if [[ -n "$NOTARIZATION_PROFILE" && "$SIGNING_IDENTITY" == "-" ]]; then
    print -u2 "公证需要通过 CODESIGN_IDENTITY 提供 Developer ID Application 证书。"
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
cp "$PRIVACY_MANIFEST" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"

# macOS 26 优先从 Assets.car 读取 Icon Composer 的 Liquid Glass 图标。
# 保留传统 .icns 作为兼容回退，并在 actool 之后复制，避免被自动生成的回退图覆盖。
xcrun actool "$COMPOSED_APP_ICON" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region zh_CN \
    --target-device mac \
    --platform macosx \
    --enable-icon-stack-fallback-generation=disabled \
    --include-all-app-icons \
    --minimum-deployment-target 15.0 \
    --output-partial-info-plist /dev/null
cp "$LEGACY_APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod 755 "$APP_BUNDLE/Contents/MacOS/PersonalAlbum"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

signing_arguments=(
    --force
    --sign "$SIGNING_IDENTITY"
    --options runtime
    --entitlements "$ENTITLEMENTS"
)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    signing_arguments+=(--timestamp)
fi
codesign "${signing_arguments[@]}" "$APP_BUNDLE"
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

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ -n "$NOTARIZATION_PROFILE" ]]; then
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZATION_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

codesign --verify --deep --strict "$APP_BUNDLE"
print "APP=$APP_BUNDLE"
print "DMG=$DMG_PATH"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    print "SIGNING=本机临时签名（未公证）"
elif [[ -z "$NOTARIZATION_PROFILE" ]]; then
    print "SIGNING=Developer ID（未公证）"
else
    print "SIGNING=Developer ID + Apple 公证"
fi
