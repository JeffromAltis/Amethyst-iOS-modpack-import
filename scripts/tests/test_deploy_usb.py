"""Exercise the deployment script with a simulated LiveContainer mount."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy_usb.sh"


class DeployUSBTests(unittest.TestCase):
    def run_transfer(self, fail_copy):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            mount = root / "mount"
            mount.mkdir()
            previous = mount / "Amethyst-latest.ipa"
            previous.write_bytes(b"previous working build")
            ipa = root / "new.ipa"
            ipa.write_bytes(b"replacement build")
            commands = {
                "idevice_id": "echo test-ipad\n",
                "ifuse": 'if [ "$1" = "--list-apps" ]; then echo \'"test.livecontainer"\'; fi\n',
                "mktemp": 'echo "$TEST_MOUNT"\n',
                "fusermount": "exit 0\n",
                "sync": "exit 0\n",
                "cp": ('echo incomplete > "$2"\nexit 1\n' if fail_copy
                       else 'exec /bin/cp "$@"\n'),
            }
            for name, body in commands.items():
                executable = tools / name
                executable.write_text("#!/bin/bash\n" + body)
                executable.chmod(0o755)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       LC_BUNDLE_ID="test.livecontainer", TEST_MOUNT=str(mount))
            result = subprocess.run(["bash", str(SCRIPT), str(ipa)], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1 if fail_copy else 0, result.stderr)
            self.assertEqual(previous.read_bytes(), b"previous working build" if fail_copy
                             else b"replacement build")
            self.assertFalse((mount / "Amethyst-latest.ipa.partial").exists())

    def test_failed_transfer_preserves_previous_build(self):
        self.run_transfer(fail_copy=True)

    def test_successful_transfer_replaces_previous_build(self):
        self.run_transfer(fail_copy=False)


if __name__ == "__main__":
    unittest.main()
