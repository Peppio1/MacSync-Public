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
test -x "$sign"
# The tarball supplies signing tools; use the official SPM XCFramework
# for compilation because its public module headers/map are provided.
curl --fail --location --silent --show-error --retry 2 \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip" \
  --output "$work/sparkle-spm.zip"
(cd "$work" && printf '%s  %s\n' '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959' sparkle-spm.zip | shasum -a 256 -c -)
mkdir "$work/spm"
ditto -x -k "$work/sparkle-spm.zip" "$work/spm"
framework="$(find "$work/spm" -type d -path '*/macos-*/Sparkle.framework' -print -quit)"
test -d "$framework"
find "$framework" -name '*.modulemap' -print
test -f "$framework/Modules/module.modulemap"
test -d "$framework/Headers"
lipo "$framework/Sparkle" -verify_arch arm64 x86_64

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
    -Xcc "-fmodule-map-file=$work/Probe.app/Contents/Frameworks/Sparkle.framework/Modules/module.modulemap" \
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

# The official release contains sign_update, not the optional sparkle-cli.
# Build an isolated test driver against the already verified public framework.
# This never launches production MacSync or uses its signing secret.
echo "Compiling isolated Sparkle installer driver"
labapp="$work/InstallLab.app"
mkdir -p "$labapp/Contents/MacOS" "$labapp/Contents/Frameworks"
ditto "$framework" "$labapp/Contents/Frameworks/Sparkle.framework"
cat > "$labapp/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.macsync.ci.driver</string>
<key>CFBundleExecutable</key><string>InstallLab</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
clang -fobjc-arc -fblocks -mmacosx-version-min=13.0 \
  -F "$labapp/Contents/Frameworks" -framework Sparkle -framework Foundation -framework AppKit \
  -Wl,-rpath,@executable_path/../Frameworks \
  Packaging/SparkleInstallLab.m -o "$labapp/Contents/MacOS/InstallLab"
codesign --force --sign - "$labapp"
codesign --verify --deep --strict "$labapp"
echo "Starting isolated Sparkle installation laboratory"
bash Packaging/test-sparkle-install-lab.sh "$archive" "$sign" "$labapp/Contents/MacOS/InstallLab" "$work/test-key"
