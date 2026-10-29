#!/usr/bin/env python3
"""Copy Amethyst logs from a USB iPad; originals remain on the device."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle-id", default="com.kdt.livecontainer.W89WFJM5TF")
    parser.add_argument("--crashes", action="store_true", help="Also copy LiveContainer/Amethyst crash reports")
    args = parser.parse_args()
    required = ["ifuse", "fusermount"] + (["idevicecrashreport"] if args.crashes else [])
    for tool in required:
        if not shutil.which(tool):
            parser.error(f"Missing tool: {tool}")
    root = Path(__file__).resolve().parents[1]
    output = args.output or root / "diagnostics/ipad" / datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    output.mkdir(parents=True, exist_ok=True)
    mount = Path(tempfile.mkdtemp(prefix="amethyst-logs-"))
    mounted = False
    copied = []
    try:
        subprocess.run(["ifuse", "--documents", args.bundle_id, "-o", "ro", str(mount)], check=True, timeout=20)
        mounted = True
        for pattern in ["latestlog*.txt", "AngelAuraAmethyst/latestlog*.txt",
                        "Data/Application/*/Documents/latestlog*.txt",
                        "Data/Application/*/Documents/AngelAuraAmethyst/latestlog*.txt"]:
            for source in mount.glob(pattern):
                relative = source.relative_to(mount)
                target = output / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
                copied.append(str(relative))
    finally:
        if mounted:
            subprocess.run(["fusermount", "-u", str(mount)], check=True, timeout=15)
        mount.rmdir()
    (output / "collection.json").write_text(json.dumps({"bundle_id": args.bundle_id, "logs": copied}, indent=2))
    if args.crashes:
        crash_dir = output / "crashes"
        crash_dir.mkdir(exist_ok=True)
        for name in ["LiveContainer", "AngelAuraAmethyst"]:
            subprocess.run(["idevicecrashreport", "--keep", "--filter", name, str(crash_dir)], check=True, timeout=120)
    print(f"Copied {len(copied)} application logs to {output}")
    print("Device originals were retained. Diagnostics may contain private data; keep them out of Git.")


if __name__ == "__main__":
    main()
