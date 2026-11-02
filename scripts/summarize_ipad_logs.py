#!/usr/bin/env python3
"""Short, redacted digest of logs collected by scripts/collect_ipad_logs.py (instead of reading raw logs).

Usage:
  scripts/summarize_ipad_logs.py                 digest of the newest collection in diagnostics/ipad/
  scripts/summarize_ipad_logs.py DIR             digest of one collection folder
  options: --tail N (last lines of the main log, default 12)  --max-lines N (hard output cap, default 70)

What it prints: which files exist, the busiest [TAG]s, the distinct problem lines (exceptions, errors, signals)
with repeat counts and the first stack frames, the last few log lines, and the newest iOS crash report decoded to
its exception and top stack frames.

Privacy: every printed line goes through redact(), which hides tokens, e-mails, account ids, IPs and similar.
That is best effort. The logs themselves stay private: do not commit or paste them.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROBLEM = re.compile(
    r"Exception|Caused by|\bERROR\b|\bSEVERE\b|\bFATAL\b|Fatal|SIGSEGV|SIGABRT|SIGBUS|EXC_|OutOfMemory|hs_err|"
    r"[Cc]rash|[Ff]ailed to|[Cc]annot |[Cc]ouldn't|[Uu]nable to|NoSuchMethod|ClassNotFound|UnsatisfiedLink|"
    r"NullPointer|IllegalState|Segmentation|\[error\]", re.I)
TAG = re.compile(r"^\[([A-Za-z0-9_ ./:+-]{1,24})\]")
NOT_A_TAG = re.compile(r"^\d\d:\d\d:\d\d$")
# lines that match PROBLEM only by accident (file names with "crash", iOS URL-scheme probes, known harmless warnings)
IGNORE = re.compile(r"canOpenURL: failed for URL|\] Extracted |fabric-crash-report|bettercrashes|BetterCrashes|"
                    r"Failed sysctl call|Reconfiguration failed: No configuration", re.I)
FRAME = re.compile(r"^\s+(?:at |\.\.\. \d+ more)")

REDACTIONS = [
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "<email>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"), "<jwt>"),
    (re.compile(r"(?i)\b(Bearer|Basic|Token|Digest)\s+\S+"), r"\1 <redacted>"),
    (re.compile(r"(--(?:accessToken|uuid|username|xuid|clientId|userProperties|session)\s+)\S+", re.I), r"\1<redacted>"),
    (re.compile(r"(?i)\b(access_?token|refresh_?token|id_?token|token|session(?:_?id)?|password|passwd|secret|"
                r"api[_-]?key|authorization|client_?secret|curseforge[_-]?key)(\"?\s*[:=]\s*\"?)[^\s\",}&]+"), r"\1\2<redacted>"),
    (re.compile(r"(?i)(Setting user:\s*)\S+"), r"\1<user>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"\b[0-9a-fA-F]{32,}\b"), "<hex>"),
    (re.compile(r"\b(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*\d)[A-Za-z0-9+/]{40,}={0,2}"), "<b64>"),
    (re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"), "<ip>"),
    (re.compile(r"/(?:home|Users)/[^/\s]+"), "/<user-home>"),
]


def redact(text):
    for pattern, replacement in REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


def clip(text, width=160):
    text = redact(text.rstrip())
    return text if len(text) <= width else text[: width - 3] + "..."


def normalize(line):
    """Key for grouping repeats: numbers and ids removed."""
    return re.sub(r"0x[0-9a-fA-F]+|\d+", "N", line.strip())[:140]


def find_collection(arg):
    base = ROOT / "diagnostics" / "ipad"
    if arg:
        path = Path(arg)
        return path if path.is_dir() else None
    for folder in sorted((d for d in base.iterdir() if d.is_dir()), reverse=True) if base.is_dir() else []:
        if any(folder.rglob("latestlog*.txt")) or any(folder.rglob("*.ips")) or any(folder.rglob("mobilegl-latest.log")):
            return folder
    return None


def read_lines(path):
    return path.read_text(errors="replace").splitlines()


def problems_in(lines, limit):
    """Distinct problem lines with repeat counts; each keeps up to two stack frames."""
    groups, order = {}, []
    i = 0
    while i < len(lines):
        line = lines[i]
        if PROBLEM.search(line) and not IGNORE.search(line) and not FRAME.match(line):
            key = normalize(line)
            frames = []
            j = i + 1
            while j < len(lines) and FRAME.match(lines[j]):
                if len(frames) < 2:
                    frames.append(lines[j])
                j += 1
            if key not in groups:
                groups[key] = {"line": line, "count": 0, "frames": frames, "first": i + 1}
                order.append(key)
            groups[key]["count"] += 1
            i = j
        else:
            i += 1
    out = []
    for key in order[:limit]:
        g = groups[key]
        out.append(f"  L{g['first']} x{g['count']}: {clip(g['line'])}")
        out.extend(f"      {clip(f, 130)}" for f in g["frames"])
    if len(order) > limit:
        out.append(f"  (+{len(order) - limit} more distinct problem lines)")
    return out, len(order)


def tag_histogram(lines, top=6):
    counts = {}
    for line in lines:
        m = TAG.match(line)
        if m and not NOT_A_TAG.match(m.group(1)):
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: -kv[1])[:top]
    return ", ".join(f"[{tag}] {n}" for tag, n in ranked) or "(no [TAG] prefixes)"


def decode_ips(path):
    """Decode an iOS .ips crash report to exception, termination reason and the faulting thread's top frames."""
    try:
        text = path.read_text(errors="replace")
        first, _, rest = text.partition("\n")
        header = json.loads(first)
        body = json.loads(rest)
    except Exception as exc:
        return [f"  {path.name}: could not parse ({type(exc).__name__})"]
    exc = body.get("exception", {})
    term = body.get("termination", {})
    lines = [f"  {path.name} | {header.get('app_name', '?')} | {header.get('os_version', '?')}",
             f"  exception: {exc.get('type', '?')} {exc.get('signal', '')} {exc.get('subtype', '')}".rstrip(),
             f"  termination: {term.get('indicator') or term.get('reason') or term.get('code', '?')}"]
    images = body.get("usedImages", [])
    threads = body.get("threads", [])
    index = body.get("faultingThread")
    if isinstance(index, int) and index < len(threads):
        lines.append(f"  faulting thread {index}:")
        for frame in threads[index].get("frames", [])[:8]:
            image = images[frame["imageIndex"]].get("name", "?") if isinstance(frame.get("imageIndex"), int) and frame["imageIndex"] < len(images) else "?"
            symbol = frame.get("symbol") or f"+{frame.get('imageOffset', '?')}"
            lines.append(f"    {image}: {symbol}")
    return [clip(l, 150) for l in lines]


def select_logs(logs, show_all):
    """Newest latestlog.txt first, then its siblings from the same app install. Older installs are only counted."""
    by_age = sorted(logs, key=lambda p: p.stat().st_mtime, reverse=True)
    mains = [p for p in by_age if p.name == "latestlog.txt"]
    if show_all or not mains:
        return by_age, 0
    main = mains[0]
    shown = [main] + [p for p in by_age if p != main and p.parent == main.parent]
    return shown, len(by_age) - len(shown)


def pretty_time(name):
    m = re.match(r"(\d{4})(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)", name)
    return f"{m[1]}-{m[2]}-{m[3]} {m[4]}:{m[5]}:{m[6]} UTC" if m else None


def build(collection, tail, max_lines, show_all=False):
    when = pretty_time(collection.name)
    out = [f"Collection: {collection.name}" + (f" ({when})" if when else "")]
    all_logs = list(collection.rglob("latestlog*.txt")) + list(collection.rglob("mobilegl-latest.log"))
    crashes = sorted(collection.rglob("*.ips"), key=lambda p: p.stat().st_mtime)
    logs, hidden = select_logs(all_logs, show_all)
    out.append(f"Files: {len(all_logs)} log(s) found, {len(crashes)} crash report(s)"
               + (f"; showing the newest app install only ({hidden} older log(s) hidden, use --all)" if hidden else ""))
    main_path = logs[0] if logs and logs[0].name == "latestlog.txt" else None
    for path in logs:
        rel = re.sub(r"Application/[^/]+", "Application/<uuid>", str(path.relative_to(collection)))
        out.append(f"- {rel}: {len(read_lines(path))} lines")
    for path in logs:
        lines = read_lines(path)
        is_main = path == main_path
        out.append(f"== {path.name}: tags: {tag_histogram(lines)}")
        found, total = problems_in(lines, 14 if is_main else 6)
        out.append(f"problems ({total} distinct):" if total else "problems: none matched")
        out.extend(found)
        if is_main:
            out.append(f"last {min(tail, len(lines))} lines:")
            out.extend("  " + clip(l, 140) for l in lines[-tail:])
    if crashes:
        out.append(f"== newest crash report (of {len(crashes)}):")
        out.extend(decode_ips(crashes[-1]))
    if len(out) > max_lines:
        dropped = len(out) - max_lines + 1
        out = out[: max_lines - 1] + [f"[output truncated: {dropped} more line(s); raise --max-lines]"]
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", nargs="?")
    parser.add_argument("--tail", type=int, default=12)
    parser.add_argument("--max-lines", type=int, default=70)
    parser.add_argument("--all", action="store_true", help="include logs from older app installs in the collection")
    args = parser.parse_args()
    collection = find_collection(args.directory)
    if collection is None:
        sys.exit("No collection found. Run scripts/collect_ipad_logs.py first (iPad connected over USB).")
    print("\n".join(build(collection, args.tail, args.max_lines, args.all)))


if __name__ == "__main__":
    main()
