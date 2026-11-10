#!/usr/bin/env python3
"""将固定版本 iroh-ffi 的 macOS 库从源码构建为 M1 / macOS 14.4 版本。"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

from macos_compat import MINIMUM_MACOS, check_binary

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "vendor/iroh-ffi"
CACHE = ROOT / ".build-iroh"
TARGET = "aarch64-apple-darwin"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_macos(commit):
    library = CACHE / "Iroh.xcframework/macos-arm64/libiroh_ffi.a"
    metadata = CACHE / "macos-compat-build.json"
    stamp = {"recipe": 1, "commit": commit, "lockfile": digest(SOURCE / "Cargo.lock"),
             "target": TARGET, "cpu": "apple-m1", "minimum_macos": MINIMUM_MACOS}
    try:
        saved = json.loads(metadata.read_text())
        if all(saved.get(key) == value for key, value in stamp.items()) and saved.get("sha256") == digest(library):
            check_binary(library)
            return
    except (OSError, ValueError):
        pass
    cargo = os.environ.get("MEOW_CARGO") or shutil.which("cargo")
    if not cargo:
        raise SystemExit("首次准备 macOS 14.4 通信库需要 Rust 1.91 或更新版本（cargo）。请先安装 Rust；安装包接收者无需安装。也可用 MEOW_CARGO 指定 cargo 路径。")
    env = dict(os.environ)
    tool_dir = Path(cargo).resolve().parent
    if (tool_dir / "rustc").exists() and tool_dir.name == "bin" and tool_dir.parent.name.startswith("1."):
        env["RUSTC"] = str(tool_dir / "rustc")
    env["MACOSX_DEPLOYMENT_TARGET"] = MINIMUM_MACOS
    env["CARGO_TARGET_DIR"] = str(CACHE / "rust-macos-14.4")
    # 固定 M1 基线，不能使用 target-cpu=native，以免在开发机上引入更新芯片指令。
    env.pop("CARGO_ENCODED_RUSTFLAGS", None)
    env["RUSTFLAGS"] = "-C target-cpu=apple-m1 --remap-path-prefix=" + str(ROOT) + "=/build/meow"
    env["CFLAGS"] = f"-mmacosx-version-min={MINIMUM_MACOS} -mcpu=apple-m1 -ffile-prefix-map={ROOT}=/build/meow"
    env["CXXFLAGS"] = env["CFLAGS"]
    print(f"首次从源码构建 iroh-ffi（M1 / macOS {MINIMUM_MACOS}，可能需要数分钟）…", flush=True)
    subprocess.run([cargo, "build", "--release", "--locked", "--lib", "--package", "iroh-ffi", "--target", TARGET],
                   cwd=SOURCE, env=env, check=True)
    built = Path(env["CARGO_TARGET_DIR"]) / TARGET / "release/libiroh_ffi.a"
    check_binary(built)
    staging = library.with_suffix(".tmp")
    shutil.copy2(built, staging)
    staging.replace(library)
    metadata.write_text(json.dumps(dict(stamp, sha256=digest(library)), indent=2) + "\n")
