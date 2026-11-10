#!/usr/bin/env python3
"""准备固定版本 iroh 绑定、校验官方头文件，并构建兼容 macOS 14.4 的通信库。"""
from pathlib import Path
import hashlib
import shutil
import subprocess
import urllib.request
import zipfile

from build_iroh_macos import prepare_macos

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "vendor" / "iroh-ffi"
CACHE = ROOT / ".build-iroh"
TAG = "v1.2.0"
COMMIT = "66a8d619a4d791d458d582f312df6e0ab42bc541"
CHECKSUM = "4a97b06ecb1d418e17a96a45b6c7e5d063a12a6dfb6600389a7b5b2ae21ae18a"
URL = f"https://github.com/n0-computer/iroh-ffi/releases/download/{TAG}/IrohLib.xcframework.zip"


def prepare():
    if not SOURCE.exists():
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", "--branch", TAG,
                        "https://github.com/n0-computer/iroh-ffi.git", str(SOURCE)], check=True)
    commit = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
    if commit != COMMIT:
        raise SystemExit("iroh-ffi 源码版本与固定二进制不一致；请先审查依赖升级，不会覆盖当前源码。")
    # 上游 Swift 包声明 14.5；本项目从同一源码重编译 macOS 库后使用 14.4。
    manifest = SOURCE / "Package.swift"
    original = manifest.read_text()
    if '.macOS("14.5")' in original:
        manifest.write_text(original.replace('.macOS("14.5")', '.macOS("14.4")', 1))
    elif '.macOS("14.4")' not in original:
        raise SystemExit("iroh-ffi 平台声明已变化，请先审查兼容性适配。")
    CACHE.mkdir(exist_ok=True)
    archive = CACHE / "IrohLib.xcframework.zip"
    if not archive.exists():
        partial = archive.with_suffix(".download")
        try:
            with urllib.request.urlopen(URL, timeout=90) as response, partial.open("wb") as out:
                shutil.copyfileobj(response, out)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != CHECKSUM:
                raise SystemExit("iroh 二进制校验失败，未使用下载文件。")
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != CHECKSUM:
        raise SystemExit("缓存的 iroh 二进制校验失败，请删除 .build-iroh/IrohLib.xcframework.zip 后重试。")
    if not (CACHE / "Iroh.xcframework/macos-arm64/libiroh_ffi.a").exists():
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.namelist():
                if not (CACHE / member).resolve().is_relative_to(CACHE.resolve()):
                    raise SystemExit("无效的依赖压缩包路径。")
            bundle.extractall(CACHE)
    prepare_macos(COMMIT)
    target = SOURCE / "Iroh.xcframework"
    if not target.exists():
        target.symlink_to("../../.build-iroh/Iroh.xcframework", target_is_directory=True)
    print(f"iroh-ffi {TAG} 已就绪（M1 起 / macOS 14.4，源码版本、官方压缩包及兼容库均已校验）")


if __name__ == "__main__":
    prepare()
