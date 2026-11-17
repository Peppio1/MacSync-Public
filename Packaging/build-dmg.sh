#!/bin/bash
set -euo pipefail
umask 022
app="$1"
graphics="$2"
out="$3"
python="$4"
test -d "$app"
test -s "$graphics/MacSync.icns"
test -s "$graphics/MacSync-DMG-Background.png"
test -s "$graphics/branding-provenance.json"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
test "$version" = 0.17.0
name="MacSync-v$version-macOS-universal.dmg"
# Test artifacts are intentionally marked with a visible CI warning in the
# Finder background and the bundled provenance. The source app is unchanged.
"$python" -m dmgbuild -s Packaging/dmg-settings.py \
  -D "app=$app" -D "guide=Packaging/Guida installazione.html" -D "graphics=$graphics" \
  "MacSync $version" "$out/$name"
hdiutil verify "$out/$name"
mount="$(mktemp -d "$RUNNER_TEMP/macsync-dmg-check.XXXXXXXX")"
attached=0
cleanup() {
  if test "$attached" = 1; then hdiutil detach "$mount" >/dev/null || true; fi
  rmdir "$mount" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$out/$name" -readonly -nobrowse -noautoopen -mountpoint "$mount"
attached=1
test -d "$mount/MacSync.app"
test -L "$mount/Applications"
test "$(readlink "$mount/Applications")" = /Applications
test -s "$mount/Guida installazione.html"
test -s "$mount/.DS_Store"
test -s "$mount/MacSync.app/Contents/Resources/MacSync.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$mount/MacSync.app/Contents/Info.plist")" = "$version"
lipo "$mount/MacSync.app/Contents/MacOS/MacSync" -verify_arch arm64 x86_64
lipo "$mount/MacSync.app/Contents/MacOS/MacSyncRecovery" -verify_arch arm64 x86_64
codesign --verify --deep --strict --all-architectures "$mount/MacSync.app"
cmp "$app/Contents/MacOS/MacSync" "$mount/MacSync.app/Contents/MacOS/MacSync"
cmp "$app/Contents/MacOS/MacSyncRecovery" "$mount/MacSync.app/Contents/MacOS/MacSyncRecovery"
cmp "$app/Contents/Resources/branding-provenance.json" "$mount/MacSync.app/Contents/Resources/branding-provenance.json"
cmp "Packaging/Guida installazione.html" "$mount/Guida installazione.html"
hdiutil detach "$mount"
attached=0
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
echo "DMG contents, mount, universal binaries, guide, and nested signatures verified."
