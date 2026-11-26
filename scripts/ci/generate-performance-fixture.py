#!/usr/bin/env python3
"""Generate the same representative synthetic image archive for both builds."""
import os
import random
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=False)
rng = random.Random(194)
for folder in range(6):
    directory = root / f"product-{folder:02d}"
    directory.mkdir()
    specs = [(f"view-{n}.jpg", 2_500_000) for n in range(4)]
    specs += [(f"raw-{n}.dng", 25_000_000) for n in range(4)]
    specs += [("edited.psd", 50_000_000)]
    for name, size in specs:
        path = directory / name
        with path.open("xb") as file:
            remaining = size
            while remaining:
                n = min(remaining, 1024 * 1024)
                file.write(rng.randbytes(n))
                remaining -= n
        os.utime(path, (time.time()-3600, time.time()-3600))
print("Synthetic fixture: 6 folders, 54 files, 960,000,000 bytes")
