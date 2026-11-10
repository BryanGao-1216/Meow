#!/bin/bash
# 云端版默认同时构建 Apple 芯片和 Intel，再合并为通用可执行文件。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-universal2}"
case "$ARCH" in
  universal2) ARCHS=(arm64 x86_64) ;;
  arm64|x86_64) ARCHS=("$ARCH") ;;
  *) echo "架构应为 universal2、arm64 或 x86_64" >&2; exit 1 ;;
esac
export MACOSX_DEPLOYMENT_TARGET="14.4"
export MEOW_CLOUD_ONLY=1
python3 "$ROOT/scripts/prepare_iroh.py"
OUTPUT="$ROOT/.build-cloud/release"
mkdir -p "$OUTPUT"
BINS=()
for target in "${ARCHS[@]}"; do
  SCRATCH="$ROOT/.build-cloud-$target"
  echo "==> 编译云端版：$target"
  swift build -c release --product Meow --arch "$target" --package-path "$ROOT" --scratch-path "$SCRATCH"
  BIN_DIR="$(swift build -c release --arch "$target" --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
  BINS+=("$BIN_DIR/Meow")
  for bundle in "$BIN_DIR/"*.bundle; do
    if [[ -d "$bundle" ]]; then
      rm -rf "$OUTPUT/$(basename "$bundle")"
      cp -R "$bundle" "$OUTPUT/"
    fi
  done
done
if [[ "$ARCH" == "universal2" ]]; then
  lipo -create "${BINS[@]}" -output "$OUTPUT/Meow"
else
  cp "${BINS[0]}" "$OUTPUT/Meow"
fi
python3 "$ROOT/scripts/macos_compat.py" "$OUTPUT/Meow" --arch "$ARCH"
