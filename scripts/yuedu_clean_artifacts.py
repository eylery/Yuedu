#!/usr/bin/env python3
"""Keep recent completed validation runs; never touch sources or source fixtures."""
import argparse
import json
import os
from pathlib import Path
import shutil
import time


def active(run):
    marker = run / "active.pid"
    if not marker.exists():
        return False
    try:
        pid = int(marker.read_text().strip())
        if pid <= 0:
            return True
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except (OSError, ValueError):
        return True  # An unreadable/foreign process is not safe to remove.


def candidates(runs, keep=2, days=7, now=None):
    now = time.time() if now is None else now
    if not runs.is_dir() or runs.is_symlink():
        return []
    managed = []
    for path in runs.iterdir():
        if path.is_symlink() or not path.is_dir() or active(path):
            continue
        try:
            manifest = json.loads((path / "yuedu-validation.json").read_text())
            if manifest.get("managedBy") == "yuedu_test.sh":
                managed.append(path)
        except (OSError, ValueError):
            continue
    managed.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    return [path for index, path in enumerate(managed)
            if index >= keep or (index > 0 and now - path.stat().st_mtime > days * 86400)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Delete the listed completed runs.")
    parser.add_argument("--keep", type=int, default=2)
    parser.add_argument("--days", type=int, default=7)
    args = parser.parse_args()
    if args.keep < 1 or args.days < 1:
        parser.error("keep and days must be positive")
    root = Path(__file__).resolve().parent.parent
    runs = root / "build" / "validation" / "runs"
    # Reject a redirected parent as well as symlinked run folders.
    if runs.resolve() != runs:
        parser.error("validation directory must not be redirected by a symbolic link")
    selected = candidates(runs, args.keep, args.days)
    for path in selected:
        print(("Deleting " if args.apply else "Would delete ") + str(path.relative_to(root)))
        if args.apply:
            shutil.rmtree(path)
    print(f"{len(selected)} completed run(s) {'removed' if args.apply else 'eligible'}; latest run and active runs are retained.")


if __name__ == "__main__":
    main()
