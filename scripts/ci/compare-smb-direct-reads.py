#!/usr/bin/env python3
"""Read-only, disposable loopback SMB comparison; never accepts production hosts."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def snapshot(root):
    # Synthetic server files only. No recursive SMB enumeration.
    rows = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "Unexpected symlink in fixture")
        rows.append((str(path.relative_to(root)), "dir" if path.is_dir() else
                     hashlib.sha256(path.read_bytes()).hexdigest()))
    return rows

def names(root):
    return [{"name": e.name, "directory": e.is_dir(follow_symlinks=False)}
            for e in os.scandir(root)]

def main():
    require(os.environ.get("MACSYNC_TEST_SMB_HOST") == "127.0.0.1"
            and os.environ.get("MACSYNC_TEST_SMB_SHARE") == "MacSyncCI",
            "Disposable loopback fixture required")
    fixture = Path(os.environ["MACSYNC_TEST_SMB_ROOT"])
    require(fixture == Path(os.environ["RUNNER_TEMP"]) / "macsync-smb-fixture",
            "Unexpected fixture root")
    mount = Path(os.environ["MACSYNC_TEST_SMB_MOUNT"])
    require(mount == fixture / "mounted", "Unexpected mount")
    raw = Path((fixture / "share-path").read_text().strip())
    require(raw.parent == Path("/private/tmp") and raw.name.startswith("macsync-ci-share."),
            "Unexpected server root")
    rclone = Path(sys.argv[1])
    require(rclone.is_file(), "Pinned Rclone executable required")
    clean = {k: v for k, v in os.environ.items() if not k.startswith("RCLONE_")}
    def run(args, *, env=clean, stdin=None):
        # Never expose credentials or unfiltered diagnostics in CI logs.
        result = subprocess.run([str(rclone), *args], env=env, input=stdin,
                                capture_output=True, text=True, timeout=60, check=False)
        require(result.returncode == 0, "Rclone command failed: " + args[0])
        return result.stdout
    auth = dict(line.split(" = ", 1) for line in
                (fixture / "smbclient-auth").read_text().splitlines() if " = " in line)
    obscure = run(["obscure", "-"], stdin=auth["password"] + "\n").strip()
    require(bool(obscure), "Missing ephemeral encoded credential")
    remote = dict(clean, RCLONE_CONFIG_MACSYNC_PROBE_TYPE="smb",
                  RCLONE_CONFIG_MACSYNC_PROBE_HOST="127.0.0.1",
                  RCLONE_CONFIG_MACSYNC_PROBE_USER=auth["username"],
                  RCLONE_CONFIG_MACSYNC_PROBE_PASS=obscure,
                  RCLONE_CONFIG_MACSYNC_PROBE_DOMAIN="WORKGROUP")
    # Each path is independently enumerated in the previous probe.
    # Distinct sentinel contents detect wrong-object opens even when
    # a backend reports success. Equal-content pairs cannot prove identity.
    cases = [
        ("macsync-ci-raw/Foto12345./child.jpg", "macsync-ci-raw/Foto12345./child.jpg"),
        ("macsync-ci-sfm/Foto12345\uF029/child.jpg", "macsync-ci-sfm/Foto12345./child.jpg"),
        ("macsync-ci-alias/keep\uF028", "macsync-ci-alias/keep "),
        ("macsync-ci-alias/keep", "macsync-ci-alias/keep"),
        ("macsync-ci-colon/Raw:old/child.jpg", "macsync-ci-colon/Raw:old/child.jpg"),
        ("macsync-ci-colon/SFM\uF022old/child.jpg", "macsync-ci-colon/SFM:old/child.jpg"),
        ("macsync-ci-colon/SFM-old/child.jpg", "macsync-ci-colon/SFM-old/child.jpg"),
        ("macsync-ci-dot-duplicates/Different\uF029/child.jpg", "macsync-ci-dot-duplicates/Different./child.jpg"),
        ("macsync-ci-dot-duplicates/Different-/child.jpg", "macsync-ci-dot-duplicates/Different-/child.jpg"),
        ("macsync-ci-dot-duplicates/Hidden./child.jpg", "macsync-ci-dot-duplicates/Hidden./child.jpg"),
        ("macsync-ci-dot-duplicates/Hidden-/child.jpg", "macsync-ci-dot-duplicates/Hidden-/child.jpg"),
    ]
    parents = sorted({server_path.split("/")[0] for server_path, _ in cases})
    before = {case: snapshot(raw / case) for case in parents}
    expected = {server_path: (raw / server_path).read_bytes() for server_path, _ in cases}
    require(all(0 < len(value) < 4096 for value in expected.values()),
            "Expected tiny nonempty synthetic sentinel")
    require(len(set(expected.values())) == len(expected),
            "Sentinel contents must be distinct")
    results = []
    for server_path, mounted_path in cases:
        truth = expected[server_path]
        try:
            actual = (mount / mounted_path).read_bytes()
            mount_status = "exact-content" if actual == truth else "different-content"
        except OSError:
            mount_status = "unreadable"
        for mode in ("default", "None"):
            env = dict(remote)
            if mode != "default":
                env["RCLONE_CONFIG_MACSYNC_PROBE_ENCODING"] = mode
            start = time.monotonic()
            # Only known, small files in the disposable fixture, no writes,
            # no hash claims based on equal metadata. Record any alias/error.
            args = ["cat", "macsync_probe:MacSyncCI/" + server_path,
                    "--config", "/dev/null", "--count", "4096",
                    "--retries", "1", "--low-level-retries", "1"]
            try:
                result = subprocess.run([str(rclone), *args], env=env,
                                        capture_output=True, timeout=30, check=False)
                if result.returncode != 0:
                    status = "read-error"
                elif result.stdout == truth:
                    status = "exact-content"
                else:
                    status = "different-content"
                alias_matches = [path for path, data in expected.items()
                                 if path != server_path and result.returncode == 0
                                 and result.stdout == data]
            except subprocess.TimeoutExpired:
                status, alias_matches = "timeout", []
            row = {
                "server_path": server_path,
                "mounted_path": mounted_path,
                "encoding": mode,
                "mount_status": mount_status,
                "direct_status": status,
                "other_matching_sentinel_paths": alias_matches,
                "seconds": round(time.monotonic() - start, 4),
            }
            results.append(row)
            print(json.dumps(row, ensure_ascii=True), flush=True)
    require(before == {case: snapshot(raw / case) for case in parents},
            "Read-only probe changed fixture")
    print("READ_ONLY_FIXTURE_UNCHANGED", flush=True)
    output = fixture / "direct-read-comparison.json"
    output.write_text(json.dumps(results, ensure_ascii=True, indent=2) + "\n")

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # Never dump a subprocess command, environment or credential.
        print("Read-only probe failed: " + (str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__),
              file=sys.stderr)
        sys.exit(1)
