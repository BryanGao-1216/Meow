#!/bin/bash
# 分发云端版：接收者只需拖入应用程序，无需开发工具或运行时安装。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { echo "--app 需要应用路径" >&2; exit 1; }
      APP="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output 需要磁盘映像路径" >&2; exit 1; }
      OUTPUT="$2"; shift 2 ;;
    --help|-h)
      echo "用法：$0 [--app 已构建的Meow.app] [--output 输出.dmg]"
      echo "默认先构建云端版；--app 可直接封装已构建并签名的应用。"
      exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "请在 macOS 上打包" >&2; exit 1; }
if [[ -z "$APP" ]]; then
  "$ROOT/scripts/package_app.sh" --cloud-only
  APP="$ROOT/build/Meow.app"
fi
[[ -d "$APP/Contents/MacOS" ]] || { echo "找不到完整的 Meow.app：$APP" >&2; exit 1; }
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "com.meow.pet" ]] || {
  echo "应用标识不匹配，未生成安装包" >&2; exit 1;
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" == "Meow" ]] || {
  echo "应用可执行文件名称不匹配" >&2; exit 1;
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "应用版本号无效" >&2; exit 1; }
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Meow")"
case "$ARCHS" in
  arm64) ARCH_LABEL=arm64 ;;
  x86_64) ARCH_LABEL=x86_64 ;;
  "arm64 x86_64"|"x86_64 arm64") ARCH_LABEL=universal2 ;;
  *) echo "不支持的应用架构：$ARCHS" >&2; exit 1 ;;
esac
codesign --verify --all-architectures --deep --strict "$APP"
python3 "$ROOT/scripts/macos_compat.py" --app "$APP" --arch "$ARCH_LABEL"

OUTPUT="${OUTPUT:-$ROOT/build/Meow-$VERSION-macOS-$ARCH_LABEL.dmg}"
[[ "$OUTPUT" == *.dmg ]] || { echo "输出文件名应以 .dmg 结尾" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/meow-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/Meow.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/packaging/安装与使用说明.txt" "$STAGING/安装与使用说明.txt"
cp "$ROOT/LICENSE" "$STAGING/开源许可.txt"
touch "$STAGING/.metadata_never_index"
codesign --verify --all-architectures --deep --strict "$STAGING/Meow.app"

echo "正在生成安装磁盘…"
hdiutil create -volname "Meow 安装" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT" >/dev/null
(
  cd "$(dirname "$OUTPUT")"
  shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
)
echo "已生成：$OUTPUT"
echo "校验文件：$OUTPUT.sha256"
echo "本机签名版首次打开可能需要系统确认；平滑分发需另行完成 Developer ID 签名和 Apple 公证。"
