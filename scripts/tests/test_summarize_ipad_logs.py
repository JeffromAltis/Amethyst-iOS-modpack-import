"""Offline tests for scripts/summarize_ipad_logs.py using synthetic logs (no real device data)."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("sil", Path(__file__).resolve().parents[1] / "summarize_ipad_logs.py")
sil = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sil)


class RedactTests(unittest.TestCase):
    def test_secrets_are_hidden(self):
        samples = {
            "mail me at someone@example.com now": "someone@example.com",
            "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.abcDEF123_-xyz": "eyJhbGci",
            "java Main --accessToken SECRETVALUE123 --version 1.21": "SECRETVALUE123",
            "java Main --username PlayerName --uuid 12345678123412341234123456789abc": "PlayerName",
            '{"access_token": "abc123SECRET", "x": 1}': "abc123SECRET",
            "Authorization: Bearer abc.def.ghi": "abc.def.ghi",
            "Setting user: SomePlayer": "SomePlayer",
            "id 123e4567-e89b-12d3-a456-426614174000 end": "123e4567",
            "hash 0123456789abcdef0123456789abcdef0123 end": "0123456789abcdef0123",
            "connecting to 192.168.12.34:25565": "192.168.12.34",
            "path /home/alex/Projects/x": "alex",
            "curseforge_key=abcDEF123456": "abcDEF123456",
        }
        for text, secret in samples.items():
            with self.subTest(text=text):
                self.assertNotIn(secret, sil.redact(text))

    def test_harmless_text_survives(self):
        for text in ["[SDL3] input bridge active", "java.lang.NullPointerException: x is null",
                     "Java_org_lwjgl_sdl_SDL3Bridge_nativeSetGrabbing", "Skipped library org.lwjgl:lwjgl-sdl:3.4.0"]:
            with self.subTest(text=text):
                self.assertEqual(sil.redact(text), text)


class ProblemTests(unittest.TestCase):
    def test_repeats_collapse_and_keep_two_frames(self):
        lines = ["[JVM] start",
                 "java.lang.IllegalStateException: boom 17", "\tat a.B.c(B.java:1)", "\tat a.B.d(B.java:2)", "\tat a.B.e(B.java:3)",
                 "[X] ok", "java.lang.IllegalStateException: boom 23"]
        out, total = sil.problems_in(lines, 10)
        self.assertEqual(total, 1)
        self.assertIn("x2", out[0])
        self.assertEqual(len([l for l in out if "at a.B" in l]), 2)

    def test_limit_is_reported(self):
        lines = [f"error number {chr(65 + i)} happened" for i in range(10)]
        out, total = sil.problems_in(lines, 3)
        self.assertEqual(total, 10)
        self.assertIn("+7 more", out[-1])

    def test_tag_histogram(self):
        self.assertTrue(sil.tag_histogram(["[A] x", "[A] y", "[B] z", "plain"]).startswith("[A] 2"))


class CrashTests(unittest.TestCase):
    def test_decode(self):
        header = {"app_name": "LiveContainer", "os_version": "iPadOS 18.6.2"}
        body = {"exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"}, "termination": {"indicator": "Segmentation fault"},
                "faultingThread": 0, "usedImages": [{"name": "libMoltenVK.dylib"}],
                "threads": [{"frames": [{"imageIndex": 0, "symbol": "vkQueueSubmit"}, {"imageIndex": 0, "imageOffset": 4096}]}]}
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.ips"
            p.write_text(json.dumps(header) + "\n" + json.dumps(body))
            text = "\n".join(sil.decode_ips(p))
        for part in ["EXC_BAD_ACCESS", "SIGSEGV", "Segmentation fault", "libMoltenVK.dylib: vkQueueSubmit"]:
            self.assertIn(part, text)

    def test_unparseable_crash_does_not_raise(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "bad.ips"
            p.write_text("not json")
            self.assertIn("could not parse", sil.decode_ips(p)[0])


class BuildTests(unittest.TestCase):
    def make(self, root, count):
        doc = root / "Data" / "Application" / "31A9EC7B-0C93-47B3-883C-58EE593DE770" / "Documents"
        doc.mkdir(parents=True)
        (doc / "latestlog.txt").write_text("\n".join(f"[T] line {i} error variant{chr(97 + i % 20)}{'x' * i}" for i in range(count)))

    def test_uuid_in_path_is_masked_and_output_is_capped(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.make(root, 400)
            text = "\n".join(sil.build(root, tail=12, max_lines=30))
        self.assertNotIn("31A9EC7B", text)
        self.assertLessEqual(len(text.splitlines()), 30)
        self.assertIn("output truncated", text)


if __name__ == "__main__":
    unittest.main()
