"""Run the production path validator on the host without the iOS runtime."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ModpackPathTests(unittest.TestCase):
    def test_production_path_validator(self):
        root = Path(__file__).resolve().parents[2]
        compiler = shutil.which("cc") or shutil.which("clang")
        self.assertIsNotNone(compiler, "A C compiler is required")
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "test_modpack_paths"
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(root / "Natives/installer/modpack"),
                            str(Path(__file__).with_suffix(".c")), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main()
