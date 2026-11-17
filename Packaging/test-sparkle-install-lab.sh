#!/bin/bash
# End-to-end Sparkle installer laboratory. Copies only, temporary test trust,
# no production app launched, no network outside localhost after SDK setup.
set -euo pipefail
umask 077
archive="$1"
sign="$2"
cli="$3"
key="$4"
root="$(mktemp -d "$RUNNER_TEMP/macsync-install-lab.XXXXXXXX")"
server=""
trap 'if test -n "$server"; then kill "$server" 2>/dev/null || true; fi; rm -rf "$root"' EXIT
test -x "$cli"
cat > "$root/pub.swift" <<'SWIFT'
import Foundation
import CryptoKit
let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: text)!)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
public="$(swift "$root/pub.swift" "$key")"
mkdir "$root/www" "$root/base" "$root/target" "$root/new"
ditto -x -k "$archive" "$root/base"
# Serve only test output on loopback using an ephemeral kernel-selected port.
cat > "$root/server.py" <<'PY'
import functools, http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root / "www"))
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    (root / "port").write_text(str(server.server_port))
    server.serve_forever()
PY
python3 "$root/server.py" "$root" > "$root/http.log" 2>&1 &
server=$!
for i in $(seq 1 100); do test -s "$root/port" && break; sleep 0.1; done
test -s "$root/port"
feed="http://127.0.0.1:$(cat "$root/port")"
labid="org.macsync.ci.install-lab"
make_fixture() {
  app="$1"; version="$2"; build="$3"; feedname="$4"
  ditto "$root/base/MacSync.app" "$app"
  info="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $labid" "$info"
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" "$info"
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $build" "$info"
  /usr/libexec/PlistBuddy -c "Set SUPublicEDKey $public" "$info"
  /usr/libexec/PlistBuddy -c "Set SUFeedURL $feed/$feedname" "$info"
  /usr/libexec/PlistBuddy -c "Add NSAppTransportSecurity dict" "$info"
  /usr/libexec/PlistBuddy -c "Add NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$info"
  codesign --force --sign - "$app"
  codesign --verify --deep --strict "$app"
}
make_fixture "$root/target/MacSync.app" 0.16.0 160 appcast.xml
make_fixture "$root/new/MacSync.app" 0.16.1 161 appcast.xml
ditto -c -k --sequesterRsrc --keepParent "$root/new/MacSync.app" "$root/www/update.zip"
sig="$("$sign" -f "$key" -p "$root/www/update.zip")"
"$sign" -f "$key" --verify "$root/www/update.zip" "$sig"
length="$(stat -f %z "$root/www/update.zip")"
cat > "$root/www/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>MacSync isolated test</title><item><title>MacSync 0.16.1</title>
<sparkle:version>161</sparkle:version><sparkle:shortVersionString>0.16.1</sparkle:shortVersionString>
<enclosure url="$feed/update.zip" sparkle:edSignature="$sig" length="$length" type="application/octet-stream"/>
</item></channel></rss>
XML
"$sign" -f "$key" "$root/www/appcast.xml" >/dev/null
"$sign" -f "$key" --verify "$root/www/appcast.xml"
# Actual Sparkle installer through the public SPUUpdater API, not merely signature verification. The
# application is not running and is not expected to be relaunched.
python3 - "$cli" "$root/target/MacSync.app" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[1], sys.argv[2]], check=True, timeout=150)
PY
for i in $(seq 1 40); do
  result="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/target/MacSync.app/Contents/Info.plist" 2>/dev/null || true)"
  test "$result" = 0.16.1 && break
  sleep 0.5
done
test "$result" = 0.16.1
codesign --verify --deep --strict "$root/target/MacSync.app"
echo "Sparkle isolated installation 0.16.0 -> 0.16.1 succeeded."
# Recreate an independent source with same trust; mutate archive while keeping
# signed feed and signature intact. No replacement may occur.
mkdir "$root/bad"
labid="org.macsync.ci.install-lab-tampered"
make_fixture "$root/bad/MacSync.app" 0.16.0 160 appcast.xml
# Use the same identifier as the update; distinct preferences are reset.
# Distinct bundle ID itself would otherwise mask the signature test.
 /usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier org.macsync.ci.install-lab' "$root/bad/MacSync.app/Contents/Info.plist"
codesign --force --sign - "$root/bad/MacSync.app"
python3 - "$root/www/update.zip" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
with p.open("r+b") as f:
    f.seek(64)
    b=f.read(1)
    f.seek(64)
    f.write(bytes([b[0]^1]))
PY
if "$sign" -f "$key" --verify "$root/www/update.zip" "$sig"; then
  echo "Tampered fixture unexpectedly verified"; exit 1
fi
python3 - "$cli" "$root/bad/MacSync.app" <<'PY'
import subprocess, sys
r=subprocess.run([sys.argv[1], sys.argv[2]],timeout=150,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
print(r.stdout)
if r.returncode not in (12,13) or "LAB: downloading" not in r.stdout:
    raise SystemExit("Tampered test did not reach download followed by an updater error")
PY
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/bad/MacSync.app/Contents/Info.plist")" = 0.16.0
codesign --verify --deep --strict "$root/bad/MacSync.app"
echo "Tampered archive did not replace the original application."
