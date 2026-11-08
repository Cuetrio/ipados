#!/usr/bin/env python3
"""Report or reclaim one owned Simulator unit-test run after its host exits."""

import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import uuid


APP_BUNDLE_ID = "com.cornellmethod.notebook.ipad.dev"


def run_root(container, run_id):
    if str(uuid.UUID(run_id)) != run_id:
        raise ValueError("run ID must be a canonical lowercase UUID")
    root = Path(container).resolve(strict=True)
    for component in ("tmp", "CornellNoteTestRuns", run_id):
        root = root / component
        if root.is_symlink() or not root.is_dir():
            raise RuntimeError("fixture run must be an existing directory without symlinked parents")
    return root


def read_owner(root, run_id):
    marker = root / "owner.json"
    if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 4096:
        raise RuntimeError("missing or unsafe fixture owner record")
    owner = json.loads(marker.read_text())
    if (not isinstance(owner, dict) or type(owner.get("schema")) is not int
            or owner["schema"] != 1 or owner.get("runID") != run_id
            or type(owner.get("hostPID")) is not int or owner["hostPID"] <= 1):
        raise ValueError("invalid fixture owner record")
    return owner


def measure_run(root):
    stats = {"directories": 1, "files": 0, "bytes": 0, "allocated_bytes": os.lstat(root).st_blocks * 512}

    def fail(error):
        raise error

    for directory, directories, files in os.walk(root, followlinks=False, onerror=fail):
        for name in directories + files:
            entry = os.lstat(Path(directory) / name)
            if stat.S_ISDIR(entry.st_mode):
                stats["directories"] += 1
            else:
                stats["files"] += 1
                stats["bytes"] += entry.st_size
            stats["allocated_bytes"] += entry.st_blocks * 512
    return stats


def ensure_host_exited(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    except PermissionError as error:
        raise RuntimeError("cannot confirm test-host exit; keeping fixtures") from error
    raise RuntimeError("test-host PID is still present (or reused); keeping fixtures")


def ensure_no_open_files(root):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", "+D", str(root)],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 1 or result.stdout.strip() or result.stderr.strip():
        raise RuntimeError("open files or inconclusive lsof inspection; keeping fixtures")


def cleanup_run(container, run_id):
    root = run_root(container, run_id)
    owner = read_owner(root, run_id)
    ensure_host_exited(owner["hostPID"])
    ensure_no_open_files(root)
    before = measure_run(root)
    if run_root(container, run_id) != root or read_owner(root, run_id) != owner:
        raise RuntimeError("fixture ownership changed; keeping fixtures")
    if not shutil.rmtree.avoids_symlink_attacks:
        raise RuntimeError("fd-safe directory removal is unavailable; keeping fixtures")
    shutil.rmtree(root)
    return before


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("report", "cleanup"))
    parser.add_argument("--device", required=True, help="explicit Simulator UUID (not 'booted')")
    parser.add_argument("--run-id", required=True, help="UUID printed by the unit tests")
    args = parser.parse_args(argv)
    try:
        uuid.UUID(args.device)
        if str(uuid.UUID(args.run_id)) != args.run_id:
            raise ValueError("run ID must be a canonical lowercase UUID")
        result = subprocess.run(
            ["xcrun", "simctl", "get_app_container", args.device, APP_BUNDLE_ID, "data"],
            check=True, capture_output=True, text=True, timeout=30,
        )
        container = Path(result.stdout.strip())
        if not container.is_absolute():
            raise RuntimeError("simctl did not return an absolute app-container path")
        root = run_root(container, args.run_id)
        read_owner(root, args.run_id)
        if args.action == "report":
            output = {"run_id": args.run_id, "retained": measure_run(root)}
        else:
            before = cleanup_run(container, args.run_id)
            output = {"run_id": args.run_id, "reclaimed": before, "remaining_run_directories": 0}
        print(json.dumps(output, sort_keys=True))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, "Fixture operation refused: " + str(error) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
