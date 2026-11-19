#!/bin/bash
# Explicit protected environment only. No key is printed or saved to disk.
# The signed candidate is never published by this script/workflow.
set -euo pipefail
umask 077
work="$RUNNER_TEMP/macsync-release-signing"
sign="$(cat "$work/tool-path")"
archive="$1"
name="$(basename "$archive")"
test "$name" = MacSync-v0.18.4-macOS-universal.zip
test -s "$archive"
test -n "${MACSYNC_SPARKLE_PRIVATE_KEY:-}" || { echo "Production signing secret not configured"; exit 1; }
# Derive public key independently using CryptoKit, check canonical encoding
# before passing the secret to any external signing tool. Never print input.
swift Packaging/verify-release-key.swift
mkdir signing-output
cp "$archive" "signing-output/$name"
dmg="$(dirname "$archive")/MacSync-v0.18.4-macOS-universal.dmg"
test -s "$dmg"
cp "$dmg" signing-output/
sig="$(printf '%s\n' "$MACSYNC_SPARKLE_PRIVATE_KEY" | "$sign" -f - -p "signing-output/$name")"
test -n "$sig"
printf '%s\n' "$MACSYNC_SPARKLE_PRIVATE_KEY" | "$sign" -f - --verify "signing-output/$name" "$sig"
# Independently verify the actual archive against the pinned public key.
swift Packaging/verify-release-key.swift "signing-output/$name" "$sig"
printf '%s\n' "$sig" > "signing-output/$name.edsignature"
(cd signing-output && shasum -a 256 "$name" > "$name.sha256")
length="$(stat -f %z "signing-output/$name")"
# This is a release PREPARATION artifact only. The production endpoint
# remains empty until an explicitly approved stable release is published.
cat > signing-output/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>MacSync</title>
<item><title>MacSync 0.18.4</title>
<sparkle:version>184</sparkle:version>
<sparkle:shortVersionString>0.18.4</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
<description>Riconoscimento archivio, gestione prudente SMB, esclusione .DS_Store e ricostruzione controllata della coda.</description>
<enclosure url="https://github.com/Peppio1/MacSync-Public/releases/download/v0.18.4/$name" sparkle:edSignature="$sig" length="$length" type="application/octet-stream"/>
</item></channel></rss>
XML
printf '%s\n' "$MACSYNC_SPARKLE_PRIVATE_KEY" | "$sign" -f - signing-output/appcast.xml > /dev/null
printf '%s\n' "$MACSYNC_SPARKLE_PRIVATE_KEY" | "$sign" -f - --verify signing-output/appcast.xml
# Public provenance only: preserve exact CI source/run and artifact hashes.
printf 'commit=%s\nrun=%s\nversion=0.18.4\n' "$GITHUB_SHA" "$GITHUB_RUN_ID" > signing-output/build-provenance.txt
(cd signing-output && shasum -a 256 "$name" MacSync-v0.18.4-macOS-universal.dmg appcast.xml "$name.edsignature" build-provenance.txt > SHA256SUMS)
(cd signing-output && shasum -a 256 -c SHA256SUMS)
echo "Production key matches pinned public key; signed candidate and feed verified. Nothing published."
