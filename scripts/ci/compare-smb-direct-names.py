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
    cases = {
        "macsync-ci-raw": "compatible-control",
        "macsync-ci-sfm": "compatible-control",
        "macsync-ci-alias": "compatible-control",
        "macsync-ci-colon": "SFM-old",
        "macsync-ci-dot-duplicates": "Equal-",
        "macsync-ci-duplicate": "Same-old",
    }
    before = {case: snapshot(raw / case) for case in cases}
    results = []
    for case, control in cases.items():
        ground = names(raw / case)
        mounted = names(mount / case)
        def as_keys(rows):
            return {(r["name"], r["directory"]) for r in rows}
        require((control, True) in as_keys(ground) and (control, True) in as_keys(mounted),
                "Missing fixture control")
        for mode in ("default", "None"):
            env = dict(remote)
            if mode != "default":
                env["RCLONE_CONFIG_MACSYNC_PROBE_ENCODING"] = mode
            start = time.monotonic()
            payload = json.loads(run(["lsjson", "macsync_probe:MacSyncCI/" + case,
                                      "--config", "/dev/null", "--max-depth", "1",
                                      "--no-mimetype", "--no-modtime",
                                      "--retries", "1", "--low-level-retries", "1"], env=env))
            require(isinstance(payload, list), "Incomplete listing")
            direct = [{"name": r["Name"], "directory": r["IsDir"]} for r in payload]
            require((control, True) in as_keys(direct), "Direct control missing")
            require(all(isinstance(r["name"], str) and "/" not in r["name"]
                        and isinstance(r["directory"], bool) for r in direct), "Invalid listing")
            # An encoding transformation or collision may defeat literal comparison.
            # Report it rather than treating the result as absence/deletion proof.
            g, m, d = as_keys(ground), as_keys(mounted), as_keys(direct)
            row = {
                "fixture": case, "encoding": mode,
                "server_names": sorted(ground, key=lambda x: x["name"]),
                "mounted_names": sorted(mounted, key=lambda x: x["name"]),
                "direct_names": sorted(direct, key=lambda x: x["name"]),
                "exact_server_names_missing_from_mount": sorted(g - m),
                "exact_server_names_missing_from_direct": sorted(g - d),
                "direct_extra_or_transformed_names": sorted(d - g),
                "direct_duplicate_entries": len(direct) - len(d),
                "direct_exact_match": g == d and len(direct) == len(d),
                "seconds": round(time.monotonic() - start, 4),
            }
            results.append(row)
            print(json.dumps(row, ensure_ascii=True), flush=True)
    require(before == {case: snapshot(raw / case) for case in cases},
            "Read-only probe changed fixture")
    print("READ_ONLY_FIXTURE_UNCHANGED", flush=True)
    output = fixture / "direct-listing-comparison.json"
    output.write_text(json.dumps(results, ensure_ascii=True, indent=2) + "\n")

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # Never dump a subprocess command, environment or credential.
        print("Read-only probe failed: " + (str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__),
              file=sys.stderr)
        sys.exit(1)
