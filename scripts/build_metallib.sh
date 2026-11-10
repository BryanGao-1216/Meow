#!/bin/bash
# Build mlx.metallib from the vendored MLX kernel sources (the non-JIT set that
# MLX's runtime fetches from the default library). Mirrors mlx/backend/metal/kernels/CMakeLists.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MLX_SRC="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNELS="$MLX_SRC/mlx/backend/metal/kernels"
OUT_DIR="${1:-$ROOT/.build/release}"
# 缓存按兼容版本隔离，避免复用在更新系统上生成的旧 AIR 文件。
WORK="$ROOT/.build/metallib-work-macos14.4"
mkdir -p "$WORK"

FLAGS=(-mmacosx-version-min=14.4 -Wall -Wextra -fno-fast-math -Wno-c++17-extensions)
INCLUDES=(-I"$MLX_SRC" -I"$KERNELS/metal_3_1")

# Non-JIT kernels (always fetched from the default metallib at runtime)
SRCS=(
  arg_reduce
  conv
  gemv
  layer_norm
  random
  rms_norm
  rope
  scaled_dot_product_attention
  fence
  steel/attn/kernels/steel_attention
)

AIRS=()
for k in "${SRCS[@]}"; do
  stem="$(basename "$k")"
  air="$WORK/$stem.air"
  if [[ ! -f "$air" || "$KERNELS/$k.metal" -nt "$air" ]]; then
    echo "metal: $k"
    xcrun -sdk macosx metal "${FLAGS[@]}" -c "$KERNELS/$k.metal" "${INCLUDES[@]}" -o "$air"
  fi
  AIRS+=("$air")
done

xcrun -sdk macosx metallib "${AIRS[@]}" -o "$OUT_DIR/mlx.metallib"
echo "wrote $OUT_DIR/mlx.metallib"
