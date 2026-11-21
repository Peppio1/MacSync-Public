#!/usr/bin/env python3
"""Time a CI command with stdout/stderr streamed live; never log its environment."""
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

if len(sys.argv) < 4 or sys.argv[2] != "--":
    raise SystemExit("Usage: record-duration.py LABEL -- COMMAND [ARGS...]")
label = sys.argv[1]
command = sys.argv[3:]
started = time.monotonic()
result = subprocess.run(command, check=False)
elapsed = time.monotonic() - started
record = {
    "label": label,
    "duration_seconds": round(elapsed, 3),
    "success": result.returncode == 0,
    "exit_code": result.returncode,
    "platform": platform.platform(),
    "architecture": platform.machine(),
}
path = Path(os.environ.get("MACSYNC_TEST_METRICS", os.environ["RUNNER_TEMP"] + "/macsync-smb-metrics.jsonl"))
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(record, sort_keys=True) + "\n")
print(f"MACSYNC_CI_DURATION {label}: {elapsed:.3f} seconds (exit {result.returncode})", flush=True)
raise SystemExit(result.returncode)
