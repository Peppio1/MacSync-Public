#!/usr/bin/env python3
"""Present observed CI wall times next to historical reference values.

Never treat different OS/architecture/test sets as a controlled speedup.
"""
import json
import os
from pathlib import Path

source = Path(os.environ.get("MACSYNC_TEST_METRICS", os.environ["RUNNER_TEMP"] + "/macsync-smb-metrics.jsonl"))
records = []
if source.exists():
    for line in source.read_text(encoding="utf-8").splitlines():
        if line.strip():
            records.append(json.loads(line))
historical = [
    ("v0.18.14 Swift suite", 248, 4, 101.780, "macos-15-intel, runner 44905111203"),
    ("v0.18.15 Swift suite", 254, 6, 81.895, "macos-15-intel, runner 44917066447"),
    ("v0.18.15 local rename 1000", 1000, 0, 5.291969, "macos-15-intel, local fixture, run 44917066447"),
]
lines = [
    "# MacSync — comparison of measured CI durations",
    "",
    "The baseline data below were extracted from successful GitHub Actions job logs.",
    "They are reference values, NOT a controlled comparison: the new SMB job",
    "uses an ARM64 runner and a real smbfs filesystem; existing jobs use Intel and local fixtures.",
    "",
    "## Previous GitHub Actions measurements",
    "",
    "| Test | Count | Skipped | Measured seconds | Environment |",
    "|---|---:|---:|---:|---|",
]
for name, count, skipped, seconds, note in historical:
    lines.append(f"| {name} | {count} | {skipped} | {seconds:.3f} | {note} |")
lines.extend([
    "",
    "## This job: measured wall time per phase",
    "",
    "| Phase | Seconds | Exit code | Runner |",
    "|---|---:|---:|---|",
])
for row in records:
    lines.append(f"| {row['label']} | {row['duration_seconds']:.3f} | {row['exit_code']} | {row['architecture']} |")
if not records:
    lines.append("| No measurements captured | — | — | — |")
lines.extend([
    "",
    "For a meaningful local-vs-SMB slowdown, compare rclone-local-control",
    "and smb-real-integration collected in the SAME job on the SAME ARM64 runner.",
    "Do not compare total CI job duration directly with an isolated test runtime.",
])
report = "\n".join(lines) + "\n"
path = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "macsync-smb-report.md"
path.write_text(report, encoding="utf-8")
print(report)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as stream:
        stream.write(report)
