#!/usr/bin/env python3
"""Compact summary of a build-fork.yml GitHub Actions run (about 10 lines instead of thousands of log lines).

Usage:
  scripts/build_summary.py                 summarize the latest run
  scripts/build_summary.py 41368471536     summarize a specific run
  scripts/build_summary.py --wait [SECS]   wait quietly until the run finishes (default 25 min), then summarize

Exit code: 0 build succeeded AND the ipa was copied to the iPad; 1 build failed or was cancelled;
3 build succeeded but the ipa was NOT copied (for example no iPad connected); 4 still running / timed out.
A green build does not prove the copy happened, which is why this checks the log for the "Copied" line.
"""
import argparse
from datetime import datetime
import json
import re
import subprocess
import sys
import time

WORKFLOW = "build-fork.yml"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
STAMP = re.compile(r"^[^\t]*\t[^\t]*\t(?:\d{4}-\d\d-\d\dT[\d:.]+Z ?)?(?:\d+:)?")
# A real failure looks like one of these. Plain mentions of the word "error" (code snippets, -Wno-error flags,
# the harmless "sysctl: cannot stat" line) are ignored on purpose.
ERROR_LINE = re.compile(
    r":\d+:\d+: (?:fatal )?error:"                 # clang: file:line:col: error: ...
    r"|\b(?:ld|lld|ld64\.lld|ld\.lld|clang\S*): (?:fatal )?error:"   # linker / driver errors
    r"|make: \*\*\* .*Error \d+"                   # make failed
    r"|curl: \(\d+\)"                              # download failed (for example the JRE zips)
    r"|##\[error\]Process completed"                # GitHub: a step exited non-zero
    r"|patch does not apply|fatal: ")
BENIGN = re.compile(r"-Wno-error|errors\.txt|grep -n|sysctl: cannot stat", re.I)


def gh(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:200]}")
    return result.stdout


def clean_lines(log_text):
    """Strip gh's job/step/timestamp prefix and ANSI colour codes from every log line."""
    for raw in log_text.splitlines():
        yield STAMP.sub("", ANSI.sub("", raw)).rstrip()


def parse_log(log_text):
    """Return the facts we care about from a build log."""
    copied = None
    no_ipad = False
    errors, warnings, seen = [], 0, set()
    for line in clean_lines(log_text):
        if re.match(r"Copied .* as Amethyst-latest\.ipa", line):
            copied = line
        if "No iPad connected; skipped USB copy" in line and line.startswith("::warning"):
            no_ipad = True
        if " warning: " in line:
            warnings += 1
        if ERROR_LINE.search(line) and not BENIGN.search(line) and not line.startswith("+"):
            key = re.sub(r"\d+", "N", line)[:120]
            if key not in seen:
                seen.add(key)
                errors.append(line[:170])
    return {"copied": copied, "no_ipad": no_ipad, "errors": errors, "warnings": warnings}


def failed_steps(jobs):
    out = []
    for job in jobs or []:
        for step in job.get("steps", []):
            if step.get("conclusion") in ("failure", "cancelled", "timed_out"):
                out.append(f"{job.get('name')}: {step.get('name')} ({step.get('conclusion')})")
    return out


def duration(start, end):
    try:
        a = datetime.fromisoformat(start.replace("Z", "+00:00"))
        b = datetime.fromisoformat(end.replace("Z", "+00:00"))
        seconds = int((b - a).total_seconds())
        return f"{seconds // 60}m{seconds % 60:02d}s"
    except Exception:
        return "?"


def run_info(run_id):
    fields = "status,conclusion,headBranch,headSha,displayTitle,event,startedAt,updatedAt,jobs"
    return json.loads(gh("run", "view", str(run_id), "--json", fields))


def render(run_id, info, parsed, artifacts):
    done = info["status"] == "completed"
    lines = [f"Run {run_id} | {info['headBranch']} @ {info['headSha'][:8]} | {info['displayTitle'][:70]!r} | {info['event']}"]
    lines.append(f"Status: {info['status']}{' / ' + info['conclusion'] if done else ''}"
                 f"{' | ' + duration(info['startedAt'], info['updatedAt']) if done else ''}")
    if not done:
        lines.append("Still running: no verdict yet.")
        return "\n".join(lines), 4
    ok = info["conclusion"] == "success"
    if not ok:
        copy = "n/a (build did not succeed)"
        code = 1
    elif parsed["copied"]:
        copy = f"COPIED: {parsed['copied'][:110]}"
        code = 0
    elif parsed["no_ipad"]:
        copy = "NOT COPIED: no iPad connected (the ipa exists only as a build artifact if upload=true)"
        code = 3
    else:
        copy = "UNKNOWN: build succeeded but the log has no 'Copied ... Amethyst-latest.ipa' line"
        code = 3
    lines.append(f"iPad copy: {copy}")
    lines.append(f"Compile: {len(parsed['errors'])} distinct error line(s), {parsed['warnings']} warning line(s)")
    steps = failed_steps(info.get("jobs"))
    lines.append("Failed steps: " + ("; ".join(steps) if steps else "none"))
    if artifacts:
        lines.append("Artifacts: " + ", ".join(artifacts))
    if parsed["errors"]:
        lines.append(f"First errors ({min(len(parsed['errors']), 8)} of {len(parsed['errors'])}):")
        lines.extend("  " + e for e in parsed["errors"][:8])
    return "\n".join(lines), code


def artifacts_for(run_id):
    try:
        repo = gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip()
        raw = gh("api", f"repos/{repo}/actions/runs/{run_id}/artifacts", "--jq",
                 '.artifacts[] | "\\(.name) \\(.size_in_bytes)"')
        return [f"{name} {int(size) / 1e6:.0f} MB" for name, size in (l.rsplit(" ", 1) for l in raw.splitlines() if l)]
    except SystemExit:
        return []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_id", nargs="?")
    parser.add_argument("--wait", nargs="?", const=1500, type=int, metavar="SECONDS")
    args = parser.parse_args()
    run_id = args.run_id or gh("run", "list", "--workflow", WORKFLOW, "--limit", "1",
                               "--json", "databaseId", "--jq", ".[0].databaseId").strip()
    if not run_id:
        raise SystemExit("no runs found")
    if args.wait:
        deadline = time.time() + args.wait
        while time.time() < deadline and run_info(run_id)["status"] != "completed":
            time.sleep(10)
    info = run_info(run_id)
    parsed = {"copied": None, "no_ipad": False, "errors": [], "warnings": 0}
    artifacts = []
    if info["status"] == "completed":
        parsed = parse_log(gh("run", "view", str(run_id), "--log"))
        artifacts = artifacts_for(run_id)
    text, code = render(run_id, info, parsed, artifacts)
    print(text)
    sys.exit(code)


if __name__ == "__main__":
    main()
