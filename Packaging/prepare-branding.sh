#!/bin/bash
set -euo pipefail
out="$1"
python="$2"
"$python" Packaging/prepare-branding.py --output "$out"
iconutil -c icns "$out/MacSync.iconset" -o "$out/MacSync.icns"
test -s "$out/MacSync.icns"
# Verify iconutil can round-trip the asset and the native menu-bar template
# remains alpha-only (black glyph). Verify source provenance explicitly.
iconutil -c iconset "$out/MacSync.icns" -o "$out/verified.iconset"
"$python" - "$out" <<'PY'
from pathlib import Path
from PIL import Image
import json,sys
p=Path(sys.argv[1])
info=json.loads((p/"branding-provenance.json").read_text())
for name,size in [("MacSyncBrand.png",(1024,1024)),("MacSyncMenuTemplate.png",(36,36)),("MacSync-DMG-Background.png",(720,430))]:
    with Image.open(p/name) as im:
        assert im.size==size
        if name!="MacSync-DMG-Background.png":
            assert im.mode=="RGBA"
            assert im.getpixel((0,0))[3]==0
            assert im.getchannel("A").getextrema()==(0,255)
            if name=="MacSyncMenuTemplate.png":
                for pixel in im.getdata():
                    if pixel[3]>0: assert pixel[:3]==(0,0,0)
sizes=set()
for file in (p/"verified.iconset").glob("*.png"):
    with Image.open(file) as im: sizes.add(im.size)
assert {(16,16),(32,32),(128,128),(256,256),(512,512),(1024,1024)} <= sizes, sizes
assert info["status"] in ("approved-original","placeholder-ci-only")
print("Icon sizes, alpha and status-bar template verified.")
PY
