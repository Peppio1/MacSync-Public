"""Only a disposable loopback Samba fixture. No operational mutations."""
import os
import pathlib
import select
import subprocess
import tempfile
import shutil
import uuid

binary = os.environ["MACSYNC_BULK_PROBE"]
mount = pathlib.Path(os.environ["MACSYNC_TEST_SMB_MOUNT"])
share = pathlib.Path(os.environ["MACSYNC_TEST_SMB_ROOT"], "share-path").read_text().strip()
server_root = pathlib.Path(share)
name = "recursive-probe-" + uuid.uuid4().hex
server = server_root / name
remote = mount / name

def build(root, links=False):
    root.mkdir(exist_ok=True)
    for d in range(12):
        folder = root / f"folder-{d:02d}"
        folder.mkdir()
        (folder / "sub").mkdir()
        for i in range(15):
            (folder / f"photo-{i:02d}-é.jpg").write_bytes(bytes([i]) * (i + 1))
            (folder / "sub" / f"raw-{i:02d}.dng").write_bytes(b"fixture")
        (folder / ".DS_Store").write_bytes(b"ignore")
    # Force more than one kernel buffer in a single directory.
    wide = root / "wide"
    wide.mkdir()
    for i in range(850):
        (wide / f"entry-{i:04d}-metadata.jpg").write_bytes(b"x")
    managed = root / ".macsync-test"
    managed.mkdir()
    (managed / "excluded").write_bytes(b"x")
    if links:
        (root / "link").symlink_to(root / "folder-00", target_is_directory=True)
        (root / "dangling").symlink_to(root / "not-present")

def compare(root, label):
    for order in ("tree-forward", "tree-reverse"):
        result = subprocess.run([binary, str(root), label, order], capture_output=True, text=True, timeout=120)
        print(result.stdout, end="", flush=True)
        if result.returncode not in (0, 2):
            raise RuntimeError(f"probe execution error: {result.returncode}")
        # A local stable fixture is the positive parser/control gate.
        # SMB inequivalence is a negative capability finding, not an
        # integration pass. Inspect results before changing the app.
        if label == "local" and result.returncode:
            raise RuntimeError("local recursive control was not equivalent")

def barrier(root, label, action):
    with subprocess.Popen([binary, str(root), label, "barrier"], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0) as p:
        try:
            # Read raw bytes to avoid TextIO buffering hiding the barrier.
            line = bytearray()
            while True:
                ready, _, _ = select.select([p.stdout], [], [], 30)
                if not ready:
                    raise RuntimeError("barrier timeout")
                ch = p.stdout.read(1)
                if not ch:
                    raise RuntimeError("child exited before barrier")
                line += ch
                if ch == b"\n":
                    if line == b"RECURSIVE_BARRIER\n":
                        break
                    line.clear()
            cmd = action()
            p.stdin.write(cmd + b"\n")
            p.stdin.flush()
            output, _ = p.communicate(timeout=120)
            print(output.decode(), end="", flush=True)
            return p.returncode, output
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()

with tempfile.TemporaryDirectory() as temp:
    local = pathlib.Path(temp) / "tree"
    try:
        build(local, links=True)
        build(server)
        compare(local, "local")
        compare(remote, "smb")
        for root, label in ((local, "local"), (remote, "smb")):
            rc, output = barrier(root, label + "-cancel", lambda: b"C")
            if rc != 2 or b"accepted=0 rows=0 cancelled=1" not in output:
                raise RuntimeError("cancelled scan published a partial result")
            def change():
                (root / "folder-00").rename(root / "folder-replaced")
                (root / "folder-00").mkdir()
                return b"G"
            rc, output = barrier(root, label + "-parent-replaced", change)
            if rc not in (0, 2):
                raise RuntimeError("replacement probe error")
            if label == "local" and (rc != 2 or b"accepted=0 rows=0" not in output):
                raise RuntimeError("local changed parent accepted")
            if rc == 0:
                print("TREE_UNSAFE_CAPABILITY replacement_not_detected", flush=True)
        # Simulated unavailable root, not a physical disconnect.
        rc = subprocess.run([binary, str(remote / "missing-root"), "smb-unavailable", "tree-forward"],
                            check=False, timeout=30).returncode
        if rc != 2:
            raise RuntimeError("missing root did not fail closed")
        print("TREE_MISSING_ROOT_REJECTED", flush=True)
    finally:
        if server.exists():
            shutil.rmtree(server)
