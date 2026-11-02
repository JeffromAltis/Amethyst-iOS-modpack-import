"""Offline tests for scripts/build_summary.py (no network, no gh)."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("build_summary", Path(__file__).resolve().parents[1] / "build_summary.py")
bs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bs)

P = "Build ipa and copy to iPad\tBuild ipa\t2026-11-02T00:41:34.7224019Z "


def log(*lines):
    return "\n".join(P + l for l in lines)


INFO = {"status": "completed", "conclusion": "success", "headBranch": "ui-rework", "headSha": "3f83616412345",
        "displayTitle": "t", "event": "workflow_dispatch", "startedAt": "2026-11-02T00:41:06Z",
        "updatedAt": "2026-11-02T00:43:52Z", "jobs": []}


class ParseLogTests(unittest.TestCase):
    def test_copied_line_found_even_with_spaces_in_job_name(self):
        parsed = bs.parse_log(log("Copied org.x.ipa to LiveContainer as Amethyst-latest.ipa."))
        self.assertTrue(parsed["copied"].startswith("Copied "))

    def test_no_ipad_warning_detected(self):
        parsed = bs.parse_log(log("::warning::No iPad connected; skipped USB copy. The ipa is still in the build artifacts."))
        self.assertTrue(parsed["no_ipad"])
        self.assertIsNone(parsed["copied"])

    def test_real_compile_error_reported_but_noise_ignored(self):
        parsed = bs.parse_log(log(
            "sysctl: cannot stat /proc/sys/hw/logicalcpu: No such file or directory",
            "  131 | + (nullable id)unarchivedObjectOfClasses:(NSSet<Class> *)classes error:(NSError **)error",
            "FLAGS=-Wno-error=incompatible-pointer-types",
            "Natives/a.m:12:5: error: use of undeclared identifier 'x'",
            "Natives/a.m:20:1: warning: unused variable 'y'"))
        self.assertEqual(len(parsed["errors"]), 1)
        self.assertIn("undeclared identifier", parsed["errors"][0])
        self.assertEqual(parsed["warnings"], 1)

    def test_download_failure_and_duplicates(self):
        parsed = bs.parse_log(log("curl: (35) Recv failure: Connection reset by peer",
                                  "make: *** [Makefile:294: jre] Error 35") +
                              "\nBuild ipa and copy to iPad\tBuild ipa\t1165:make: *** [Makefile:294: jre] Error 35")
        self.assertEqual(len(parsed["errors"]), 2)


class RenderTests(unittest.TestCase):
    def test_success_and_copied_is_exit_0(self):
        text, code = bs.render("1", INFO, {"copied": "Copied a as Amethyst-latest.ipa.", "no_ipad": False, "errors": [], "warnings": 3}, [])
        self.assertEqual(code, 0)
        self.assertIn("COPIED", text)
        self.assertIn("2m46s", text)

    def test_green_build_without_copy_is_not_exit_0(self):
        text, code = bs.render("1", INFO, {"copied": None, "no_ipad": True, "errors": [], "warnings": 0}, [])
        self.assertEqual(code, 3)
        self.assertIn("NOT COPIED", text)

    def test_unknown_when_no_copy_line_and_no_warning(self):
        _, code = bs.render("1", INFO, {"copied": None, "no_ipad": False, "errors": [], "warnings": 0}, [])
        self.assertEqual(code, 3)

    def test_failure_is_exit_1_and_lists_failed_steps(self):
        info = dict(INFO, conclusion="failure", jobs=[{"name": "J", "steps": [{"name": "Build ipa", "conclusion": "failure"}]}])
        text, code = bs.render("1", info, {"copied": None, "no_ipad": False, "errors": ["boom"], "warnings": 0}, [])
        self.assertEqual(code, 1)
        self.assertIn("J: Build ipa (failure)", text)
        self.assertIn("boom", text)

    def test_running_is_exit_4(self):
        _, code = bs.render("1", dict(INFO, status="in_progress", conclusion=None), {}, [])
        self.assertEqual(code, 4)


if __name__ == "__main__":
    unittest.main()
