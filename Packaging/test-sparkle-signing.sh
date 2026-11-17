#!/bin/bash
# CI-only: ephemeral keys, no publication, no production trust material.
set -euo pipefail
umask 077
archive="$1"
test -s "$archive"
work="$(mktemp -d "$RUNNER_TEMP/macsync-sparkle.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
curl --fail --location --silent --show-error --retry 2 \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz" \
  --output "$work/sparkle.tar.xz"
(cd "$work" && printf '%s  %s\n' 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c' sparkle.tar.xz | shasum -a 256 -c -)
mkdir "$work/sdk"
tar -xJf "$work/sparkle.tar.xz" -C "$work/sdk"
sign="$(find "$work/sdk" -type f -path '*/bin/sign_update' -print -quit)"
framework="$(find "$work/sdk" -type d -name Sparkle.framework -print -quit)"
test -x "$sign"
test -d "$framework"

# Verify the external binary can be linked and loaded by the existing
# Swift 5.9 / Xcode toolchain, including both architectures. Never start
# an updater or alter the user's installed application in this smoke test.
mkdir -p "$work/Probe.app/Contents/MacOS" "$work/Probe.app/Contents/Frameworks"
ditto "$framework" "$work/Probe.app/Contents/Frameworks/Sparkle.framework"
cat > "$work/probe.swift" <<'SWIFT'
import AppKit
import Sparkle
import Foundation
@main
struct Probe {
    @MainActor static func main() {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        print("Sparkle loaded: \(controller.updater)")
    }
}
SWIFT
for arch in arm64 x86_64; do
  swiftc -parse-as-library -warnings-as-errors -target "$arch-apple-macos13.0" \
    -F "$work/Probe.app/Contents/Frameworks" -framework Sparkle \
    -Xlinker -rpath -Xlinker '@loader_path/../Frameworks' \
    "$work/probe.swift" -o "$work/probe-$arch"
  lipo "$work/probe-$arch" -verify_arch "$arch"
done
lipo -create "$work/probe-arm64" "$work/probe-x86_64" -output "$work/Probe.app/Contents/MacOS/Probe"
lipo "$work/Probe.app/Contents/MacOS/Probe" -verify_arch arm64 x86_64
lipo "$work/Probe.app/Contents/Frameworks/Sparkle.framework/Sparkle" -verify_arch arm64 x86_64
cat > "$work/Probe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.macsync.sparkle-ci-probe</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Framework distribution carries its own nested helper signatures.
codesign --force --sign - "$work/Probe.app"
codesign --verify --deep --strict --verbose=2 "$work/Probe.app"
"$work/Probe.app/Contents/MacOS/Probe"

# Generate a random *test* seed in a private, disposable directory.
# Sparkle 2.10 accepts a base64 32-byte Ed25519 seed from a private file.
# No key is written to stdout, variables in Actions, Git, or artifacts.
openssl rand -base64 32 > "$work/test-key"
openssl rand -base64 32 > "$work/other-key"
sig="$("$sign" -f "$work/test-key" -p "$archive")"
test -n "$sig"
"$sign" -f "$work/test-key" --verify "$archive" "$sig"
cp "$archive" "$work/tampered.zip"
printf 'tampered' >> "$work/tampered.zip"
if "$sign" -f "$work/test-key" --verify "$work/tampered.zip" "$sig"; then
  echo "ERROR: altered archive accepted"; exit 1
fi
if "$sign" -f "$work/other-key" --verify "$archive" "$sig"; then
  echo "ERROR: wrong signing key accepted"; exit 1
fi
# Signed RSS test fixture only; no production appcast.
cat > "$work/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>MacSync signing fixture</title><item><title>Test</title><sparkle:version>999</sparkle:version></item>
</channel></rss>
XML
"$sign" -f "$work/test-key" "$work/appcast.xml" >/dev/null
"$sign" -f "$work/test-key" --verify "$work/appcast.xml"
cp "$work/appcast.xml" "$work/altered.xml"
# Change actual signed XML content without changing its length.
sed -i '' 's/signing fixture/signing altered/' "$work/altered.xml"
if "$sign" -f "$work/test-key" --verify "$work/altered.xml"; then
  echo "ERROR: altered feed accepted"; exit 1
fi
echo "Sparkle framework linking, signing and tamper rejection passed"
