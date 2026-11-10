#!/usr/bin/env python3
"""检查实际 Mach-O 的架构和最低系统版本，防止只降低 Info.plist 后误发包。"""
from pathlib import Path
import argparse
import plistlib
import re
import subprocess

MINIMUM_MACOS = "14.4"


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def check_binary(path):
    path = Path(path)
    architectures = subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    if architectures != ["arm64"]:
        raise ValueError(f"{path.name} 的架构为 {architectures}，应为兼容 M1 的 arm64。")
    commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", commands, re.MULTILINE)
    if any(platform not in {"1", "MACOS"} for platform in platforms):
        raise ValueError(f"{path.name} 包含非 macOS 平台的代码。")
    floors = re.findall(r"^\s*minos\s+([\d.]+)\s*$", commands, re.MULTILINE)
    floors += re.findall(r"cmd LC_VERSION_MIN_MACOSX\n\s*cmdsize \d+\n\s*version ([\d.]+)", commands)
    if not floors:
        raise ValueError(f"无法读取 {path.name} 的最低 macOS 版本。")
    newest = max(floors, key=version)
    if version(newest) > version(MINIMUM_MACOS):
        raise ValueError(f"{path.name} 内仍含要求 macOS {newest} 的代码，不能在 {MINIMUM_MACOS} 分发。")
    return newest


def check_app(path):
    path = Path(path)
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("LSMinimumSystemVersion") != MINIMUM_MACOS:
        raise ValueError(f"Info.plist 最低系统版本应为 {MINIMUM_MACOS}。")
    main = path / "Contents/MacOS" / info["CFBundleExecutable"]
    binaries = {main}
    # 也检查嵌入的动态库/框架；模型、图标和 metallib 不属于 Mach-O。
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    for item in (path / "Contents").rglob("*"):
        if item.is_file() and not item.is_symlink():
            with item.open("rb") as stream:
                if stream.read(4) in magic:
                    binaries.add(item)
    for binary in sorted(binaries):
        check_binary(binary)
    print(f"兼容性检查通过：arm64（M1 起），最低 macOS {MINIMUM_MACOS}，已检查 {len(binaries)} 个可执行文件/动态库。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?")
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        if args.app:
            check_app(args.app)
        elif args.binary:
            print(f"{args.binary}：arm64，最低 macOS {check_binary(args.binary)}")
        else:
            parser.error("请提供 Mach-O 文件或 --app 应用路径。")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"兼容性检查失败：{error}")


if __name__ == "__main__":
    main()
