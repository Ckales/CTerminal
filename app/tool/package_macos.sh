#!/bin/sh
# 打包 macOS 发布件：签名 →（有凭据时）公证 + 装订 → DMG（带 /Applications 链接）。
# 用法：sh app/tool/package_macos.sh <已构建的 CTerminal.app> <输出目录>
# 输入的 .app 不会被修改：先复制到临时目录再签名。
#
# 环境变量（都可缺省，缺省时降级）：
#   MACOS_SIGN_IDENTITY   Developer ID Application 证书名；缺省时 ad-hoc 签名（只能本机运行）
#   公证凭据二选一，缺省时跳过公证：
#     APPLE_API_KEY_ID + APPLE_API_ISSUER + APPLE_API_KEY_PATH（App Store Connect API 密钥，.p8 文件路径）
#     APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD（App 专用密码）
# 脚本不打印任何凭据。
set -eu

if [ $# -ne 2 ]; then
    echo "用法：sh $0 <CTerminal.app> <输出目录>" >&2
    exit 2
fi
APP_IN=$1
OUT_DIR=$2
if [ ! -d "$APP_IN/Contents/MacOS" ]; then
    echo "不是 .app 包：$APP_IN" >&2
    exit 1
fi
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/macos/Runner/Release.entitlements"
NAME=$(basename "$APP_IN" .app)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_IN/Contents/Info.plist")

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cterminal-package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/dmg"
APP="$STAGE/$NAME.app"
mkdir "$STAGE"
# ditto 保留符号链接和扩展属性（framework 的 Versions/Current 靠符号链接）
ditto "$APP_IN" "$APP"

sign() {
    if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
        codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$@"
    else
        codesign --force --sign - "$@"
    fi
}

if [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
    echo "警告：未设置 MACOS_SIGN_IDENTITY，使用 ad-hoc 签名。产物只适合本机测试，其他机器上会被 Gatekeeper 拦截。" >&2
fi

# 由内向外签：先嵌入的 dylib 和 framework（Rust 静态库链接在 cterminal_rust.framework 里），最后签整个 app
find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) | while read -r library; do
    sign "$library"
done
for framework in "$APP/Contents/Frameworks/"*.framework; do
    if [ -d "$framework" ]; then
        sign "$framework"
    fi
done
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notary() {
    if [ -n "${APPLE_API_KEY_ID:-}" ]; then
        xcrun notarytool "$@" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
    else
        xcrun notarytool "$@" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
    fi
}

HAS_API_KEY=false
if [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ] && [ -n "${APPLE_API_KEY_PATH:-}" ]; then
    HAS_API_KEY=true
fi
HAS_APPLE_ID=false
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    HAS_APPLE_ID=true
fi

if [ "$HAS_API_KEY" = false ] && [ "$HAS_APPLE_ID" = false ]; then
    echo "未配置公证凭据，跳过公证。" >&2
elif [ -z "${MACOS_SIGN_IDENTITY:-}" ]; then
    echo "有公证凭据但没有 Developer ID 签名，ad-hoc 签名无法公证，跳过公证。" >&2
else
    if [ "$HAS_API_KEY" = false ]; then
        unset APPLE_API_KEY_ID
    fi
    echo "提交公证（通常需要几分钟）…"
    ZIP="$WORK/$NAME.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    RESULT=$(notary submit "$ZIP" --wait --output-format json)
    STATUS=$(printf '%s' "$RESULT" | plutil -extract status raw -o - -)
    if [ "$STATUS" != "Accepted" ]; then
        SUBMISSION=$(printf '%s' "$RESULT" | plutil -extract id raw -o - -)
        echo "公证未通过：$STATUS，日志如下" >&2
        notary log "$SUBMISSION" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

ln -s /Applications "$STAGE/Applications"
DMG="$OUT_DIR/$NAME-$VERSION-macos.dmg"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null
echo "$DMG"
