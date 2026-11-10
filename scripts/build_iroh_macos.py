#!/usr/bin/env python3
"""从固定源码构建 Apple 芯片和 Intel 通信库，组装 macOS 14.4 通用 XCFramework。"""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess

from macos_compat import MINIMUM_MACOS, check_binary

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "vendor/iroh-ffi"
CACHE = ROOT / ".build-iroh"
TARGETS = {"arm64": ("aarch64-apple-darwin", "apple-m1"),
           "x86_64": ("x86_64-apple-darwin", "x86-64")}
MACOS_SLICE = "macos-arm64_x86_64"
UNIVERSAL_FRAMEWORK = CACHE / "Iroh-universal.xcframework"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_architecture(commit, arch):
    target, cpu = TARGETS[arch]
    library = CACHE / "macos" / arch / "libiroh_ffi.a"
    metadata = library.with_suffix(".json")
    stamp = {"recipe": 1, "commit": commit, "lockfile": digest(SOURCE / "Cargo.lock"),
             "target": target, "cpu": cpu, "minimum_macos": MINIMUM_MACOS}
    # 复用前一版已经验证的 arm64 源码构建结果，不重复构建，也不使用官方 14.5 库。
    legacy_metadata = CACHE / "macos-compat-build.json"
    legacy_library = CACHE / "Iroh.xcframework/macos-arm64/libiroh_ffi.a"
    if arch == "arm64" and not metadata.exists() and legacy_metadata.exists() and legacy_library.exists():
        try:
            saved = json.loads(legacy_metadata.read_text())
        except (OSError, ValueError):
            saved = {}
        if all(saved.get(key) == value for key, value in stamp.items()) and saved.get("sha256") == digest(legacy_library):
            check_binary(legacy_library, {arch})
            library.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(legacy_library, library)
            shutil.copy2(legacy_metadata, metadata)
    try:
        saved = json.loads(metadata.read_text())
        if all(saved.get(key) == value for key, value in stamp.items()) and saved.get("sha256") == digest(library):
            check_binary(library, {arch})
            return library
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
    # 使用各自的兼容基线，不能使用 target-cpu=native。
    env.pop("CARGO_ENCODED_RUSTFLAGS", None)
    env["RUSTFLAGS"] = f"-C target-cpu={cpu} --remap-path-prefix={ROOT}=/build/meow"
    cpu_flags = "-mcpu=apple-m1" if arch == "arm64" else "-march=x86-64 -mtune=generic"
    env["CFLAGS"] = f"-mmacosx-version-min={MINIMUM_MACOS} {cpu_flags} -ffile-prefix-map={ROOT}=/build/meow"
    env["CXXFLAGS"] = env["CFLAGS"]
    print(f"首次从源码构建 iroh-ffi（{arch} / macOS {MINIMUM_MACOS}，可能需要数分钟；Rust 须安装 {target} 目标）…", flush=True)
    subprocess.run([cargo, "build", "--release", "--locked", "--lib", "--package", "iroh-ffi", "--target", target],
                   cwd=SOURCE, env=env, check=True)
    built = Path(env["CARGO_TARGET_DIR"]) / target / "release/libiroh_ffi.a"
    check_binary(built, {arch})
    library.parent.mkdir(parents=True, exist_ok=True)
    staging = library.with_suffix(".tmp")
    shutil.copy2(built, staging)
    staging.replace(library)
    metadata.write_text(json.dumps(dict(stamp, sha256=digest(library)), indent=2) + "\n")
    return library


def prepare_macos(commit):
    libraries = [build_architecture(commit, arch) for arch in TARGETS]
    headers = CACHE / "Iroh.xcframework/macos-arm64/Headers"
    slice_dir = UNIVERSAL_FRAMEWORK / MACOS_SLICE
    slice_dir.mkdir(parents=True, exist_ok=True)
    merged = slice_dir / "libiroh_ffi.a"
    manifest = {"sha256": [digest(lib) for lib in libraries], "minimum_macos": MINIMUM_MACOS}
    metadata = UNIVERSAL_FRAMEWORK / "meow-build.json"
    try:
        saved = json.loads(metadata.read_text())
    except (OSError, ValueError):
        saved = {}
    if saved.get("inputs") != manifest or not merged.exists() or saved.get("sha256") != digest(merged):
        temporary = merged.with_suffix(".tmp")
        subprocess.run(["lipo", "-create", *map(str, libraries), "-output", str(temporary)], check=True)
        check_binary(temporary, set(TARGETS))
        temporary.replace(merged)
    check_binary(merged, set(TARGETS))
    shutil.copytree(headers, slice_dir / "Headers", dirs_exist_ok=True)
    info = {"CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0", "AvailableLibraries": [
        {"LibraryIdentifier": MACOS_SLICE, "LibraryPath": "libiroh_ffi.a", "HeadersPath": "Headers",
         "SupportedArchitectures": list(TARGETS), "SupportedPlatform": "macos"}]}
    (UNIVERSAL_FRAMEWORK / "Info.plist").write_bytes(plistlib.dumps(info))
    metadata.write_text(json.dumps({"inputs": manifest, "sha256": digest(merged)}, indent=2) + "\n")
    return UNIVERSAL_FRAMEWORK
