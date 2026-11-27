"""Disconnect only the disposable loopback Samba server while the reader is open."""
import os
import pathlib
import select
import socket
import subprocess
import time
import uuid

binary = os.environ["MACSYNC_BULK_PROBE"]
base = pathlib.Path(os.environ["MACSYNC_TEST_SMB_ROOT"])
mount = pathlib.Path(os.environ["MACSYNC_TEST_SMB_MOUNT"])
assert base == pathlib.Path(os.environ["RUNNER_TEMP"]) / "macsync-smb-fixture"
assert mount == base / "mounted"
assert os.environ["MACSYNC_TEST_SMB_HOST"] == "127.0.0.1"
assert os.environ["MACSYNC_TEST_SMB_SHARE"] == "MacSyncCI"
config = base / "smb.conf"
assert "interfaces = 127.0.0.1" in config.read_text()
assert "bind interfaces only = yes" in config.read_text()
share = pathlib.Path((base / "share-path").read_text().strip())
assert str(share).startswith("/private/tmp/macsync-ci-share.")
name = "outage-probe-" + uuid.uuid4().hex
fixture = share / name
fixture.mkdir()
for d in range(8):
    folder = fixture / f"folder-{d}"
    folder.mkdir()
    for i in range(20):
        (folder / f"file-{i}.jpg").write_bytes(b"synthetic")
remote = mount / name
# Fresh nested directories have not been enumerated by the mount.
control = subprocess.run(["brew", "--prefix"], capture_output=True, text=True, check=True).stdout.strip() + "/bin/smbcontrol"
p = subprocess.Popen([binary, str(remote), "smb-outage", "barrier"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
try:
    line = bytearray()
    deadline = time.monotonic() + 30
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([p.stdout], [], [], remaining)[0]:
            raise RuntimeError("reader did not reach listing barrier")
        ch = p.stdout.read(1)
        if not ch:
            raise RuntimeError("reader exited before barrier")
        line += ch
        if ch == b"\n":
            if line == b"RECURSIVE_BARRIER\n":
                break
            line.clear()
    # Existing fixture cleanup uses this exact command and private config.
    # No global process kill, firewall change or production network access.
    subprocess.run(["sudo", "-n", control, "-s", str(config), "smbd", "shutdown"],
                   check=True, timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", 445), timeout=0.25):
                pass
        except OSError:
            break
        time.sleep(0.2)
    else:
        raise RuntimeError("disposable server still listening; outage not demonstrated")
    print("SMB_OUTAGE_SERVER_STOPPED", flush=True)
    p.stdin.write(b"G\n")
    p.stdin.flush()
    try:
        output, _ = p.communicate(timeout=30)
        print(output.decode(), end="", flush=True)
        if p.returncode == 2 and b"accepted=0 rows=0" in output:
            print("SMB_OUTAGE_REJECTED", flush=True)
        elif p.returncode == 0:
            print("SMB_OUTAGE_UNSAFE_CAPABILITY cached_or_incomplete_inventory_accepted", flush=True)
        else:
            raise RuntimeError(f"unexpected reader exit {p.returncode}")
    except subprocess.TimeoutExpired:
        # A blocked kernel call is not a successful rejection. The app
        # must discard the result and retain its isolated read lane.
        print("SMB_OUTAGE_BLOCKED_KERNEL_READ", flush=True)
finally:
    if p.poll() is None:
        p.kill()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            print("SMB_OUTAGE_READER_STILL_PENDING", flush=True)
# Existing always-run fixture cleanup unmounts and removes only its own share.
