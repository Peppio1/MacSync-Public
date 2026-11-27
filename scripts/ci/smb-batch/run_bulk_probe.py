"""Disposable CI fixtures only; preserve the current scanner regardless of outcome."""
import os
import pathlib
import subprocess
import tempfile
import shutil
import uuid

binary = os.environ["MACSYNC_BULK_PROBE"]
mount = pathlib.Path(os.environ["MACSYNC_TEST_SMB_MOUNT"])
with tempfile.TemporaryDirectory() as temp:
    local = pathlib.Path(temp)
    remote = mount / ("bulk-probe-" + uuid.uuid4().hex)
    remote.mkdir()
    try:
        for root, label in ((local, "local"), (remote, "smb")):
            for i in range(120):
                (root / f"photo-{i:03d}-é.jpg").write_bytes(bytes([i]) * (i + 1))
            (root / "nested").mkdir()
            (root / ".DS_Store").write_bytes(b"fixture")
            (root / "case-Control").write_bytes(b"control")
            if label == "local":
                (root / "link").symlink_to(root / "nested", target_is_directory=True)
                (root / "dangling").symlink_to(root / "does-not-exist")
            for order in ("forward", "reverse"):
                result = subprocess.run([binary, str(root), label, order], check=False)
                if result.returncode not in (0, 2):
                    raise RuntimeError(f"probe execution failed: {label}: {result.returncode}")
        # Existing deliberately incompatible literal/SFM name fixtures.
        for name in ("raw", "sfm", "alias", "colon", "dot-duplicates"):
            folder = mount / ("macsync-ci-" + name)
            result = subprocess.run([binary, str(folder), "smb-" + name, "forward"], check=False)
            if result.returncode not in (0, 2):
                raise RuntimeError(f"probe execution failed: {name}: {result.returncode}")
    finally:
        shutil.rmtree(remote)
