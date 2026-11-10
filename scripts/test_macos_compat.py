#!/usr/bin/env python3
"""用真实编译的 Mach-O 样例验证分发兼容性检查，不启动 Meow。"""
from pathlib import Path
import contextlib
import io
import plistlib
import shutil
import subprocess
import tempfile
import unittest

from macos_compat import check_app, check_binary


class MacOSCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="meow-compat-test-")
        cls.root = Path(cls.temp.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        for arch, floor, name in [("arm64", "14.4", "supported"), ("arm64", "14.5", "newer"),
                                  ("x86_64", "14.4", "intel")]:
            subprocess.run(["clang", "-target", f"{arch}-apple-macosx{floor}", str(source), "-o", str(cls.root / name)],
                           check=True, capture_output=True)
        subprocess.run(["clang", "-target", "arm64-apple-macosx14.5", "-c", str(source), "-o", str(cls.root / "newer.o")],
                       check=True, capture_output=True)
        subprocess.run(["ar", "rcs", str(cls.root / "newer.a"), str(cls.root / "newer.o")], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def app(self, name, binary, floor="14.4"):
        app = self.root / (name + ".app")
        (app / "Contents/MacOS").mkdir(parents=True)
        shutil.copy2(self.root / binary, app / "Contents/MacOS/Meow")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleExecutable": "Meow", "LSMinimumSystemVersion": floor}))
        return app

    def test_accepts_actual_14_4_arm64_executable(self):
        self.assertEqual(check_binary(self.root / "supported"), "14.4")

    def test_rejects_actual_14_5_executable(self):
        with self.assertRaisesRegex(ValueError, "14.5"):
            check_binary(self.root / "newer")

    def test_rejects_newer_static_library_members(self):
        with self.assertRaisesRegex(ValueError, "14.5"):
            check_binary(self.root / "newer.a")

    def test_rejects_intel_binary(self):
        with self.assertRaisesRegex(ValueError, "arm64"):
            check_binary(self.root / "intel")

    def test_lowering_plist_alone_is_not_enough(self):
        with self.assertRaisesRegex(ValueError, "14.5"):
            check_app(self.app("changed-plist", "newer"))

    def test_checks_embedded_native_files(self):
        app = self.app("embedded", "supported")
        (app / "Contents/Frameworks").mkdir()
        shutil.copy2(self.root / "newer", app / "Contents/Frameworks/Newer.dylib")
        with self.assertRaisesRegex(ValueError, "14.5"):
            check_app(app)

    def test_checks_bundle_declaration(self):
        with self.assertRaisesRegex(ValueError, "Info.plist"):
            check_app(self.app("newer-plist", "supported", "14.5"))

    def test_accepts_matching_app(self):
        with contextlib.redirect_stdout(io.StringIO()):
            check_app(self.app("supported-bundle", "supported"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
