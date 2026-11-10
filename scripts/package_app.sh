#!/bin/bash
# 打包 Meow：可执行文件、可选本地模型和图标。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Meow"
APP_VERSION="${MEOW_VERSION:-1.0.8}"
APP_BUILD="${MEOW_BUILD_NUMBER:-9}"
SIGNING_IDENTITY="${MEOW_CODESIGN_IDENTITY:--}"
export MACOSX_DEPLOYMENT_TARGET="14.4"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "版本号无效" >&2; exit 1; }
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || { echo "构建号无效" >&2; exit 1; }
APP="$ROOT/build/$APP_NAME.app"
BIN="$ROOT/.build/release/Meow"
CLOUD_ONLY=0
ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud-only) CLOUD_ONLY=1; shift ;;
    --arch)
      [[ $# -ge 2 ]] || { echo "--arch 需要架构名称" >&2; exit 1; }
      ARCH="$2"; shift 2 ;;
    *) echo "用法：$0 [--cloud-only] [--arch universal2|arm64|x86_64]" >&2; exit 1 ;;
  esac
done
if [[ -z "$ARCH" ]]; then
  if [[ "$CLOUD_ONLY" == "1" ]]; then ARCH=universal2; else ARCH=arm64; fi
fi
case "$ARCH" in universal2|arm64|x86_64) ;; *) echo "架构名称无效" >&2; exit 1 ;; esac
if [[ "$CLOUD_ONLY" == "0" && "$ARCH" != "arm64" ]]; then
  echo "当前本地 MLX 模式仅构建 Apple 芯片版；Intel 或通用版请加 --cloud-only。" >&2; exit 1
fi

echo "==> swift build"
if [[ "$CLOUD_ONLY" == "1" ]]; then
  bash "$ROOT/scripts/build_cloud.sh" "$ARCH"
  BIN="$ROOT/.build-cloud/release/Meow"
else
  python3 "$ROOT/scripts/prepare_iroh.py"
  swift build -c release --arch arm64 --package-path "$ROOT" >/dev/null
fi
BIN_DIR="$(dirname "$BIN")"

if [[ "$CLOUD_ONLY" == "0" ]]; then
  echo "==> metallib"
  "$ROOT/scripts/build_metallib.sh" "$ROOT/.build/release" >/dev/null
fi

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp "$ROOT/vendor/iroh-ffi/LICENSE-MIT" "$APP/Contents/Resources/ThirdPartyLicenses/iroh-ffi-MIT.txt"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# MLX looks for a colocated mlx.metallib next to the executable
if [[ "$CLOUD_ONLY" == "0" ]]; then
  cp "$BIN_DIR/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"
fi
# SwiftPM resource bundles (swift-transformers fallback configs)
for b in "$BIN_DIR/"*.bundle; do
  [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/" || true
done

if [[ "$CLOUD_ONLY" == "0" ]]; then
  echo "==> model weights"
  mkdir -p "$APP/Contents/Resources/model"
  for f in config.json generation_config.json model.safetensors model.safetensors.index.json \
           tokenizer.json tokenizer_config.json chat_template.jinja; do
    cp "$ROOT/model/$f" "$APP/Contents/Resources/model/"
  done
fi

echo "==> icon"
ICONDIR="$ROOT/build/icon.iconset"
rm -rf "$ICONDIR"; mkdir -p "$ICONDIR"
"$BIN" --icon "$ROOT/build" >/dev/null
SRC="$ROOT/build/icon-1024.png"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONDIR/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$SRC" --out "$ICONDIR/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONDIR" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.meow.pet</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>NSLocalNetworkUsageDescription</key><string>喵喵信箱需要连接已绑定的另一台 Mac，用来寄送和接收文本信件。</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
python3 "$ROOT/scripts/macos_compat.py" --app "$APP" --arch "$ARCH"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "==> 本机签名（更新二进制后，钥匙串可能需要重新授权）"
  codesign --force --deep -s - "$APP"
else
  echo "==> 使用指定身份签名"
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --all-architectures --deep --strict "$APP"

du -sh "$APP"
echo "done: $APP"
