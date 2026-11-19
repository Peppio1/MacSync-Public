#!/bin/bash
set -euo pipefail
out="$1"
mkdir -p "$out"
version=1.76.0
for arch in arm64 amd64; do
  case "$arch" in
    arm64) digest=e72dc90b70f4947a7b72b61bde4a4fbba5777b2874fb448951ffdde67ebd0ab7 ;;
    amd64) digest=4f5835733d52b818340f97b1fc0348a70461534d123363a183ca2b660219595a ;;
  esac
  name="rclone-v$version-osx-$arch"
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/rclone/rclone/releases/download/v$version/$name.zip" -o "$out/$name.zip"
  printf '%s  %s\n' "$digest" "$out/$name.zip" | shasum -a 256 -c -
  unzip -q "$out/$name.zip" -d "$out"
  test -x "$out/$name/rclone"
  printf '%s %s\n' "$digest" "$name.zip" >> "$out/provenance.txt"
done
lipo -create "$out/rclone-v$version-osx-arm64/rclone" "$out/rclone-v$version-osx-amd64/rclone" -output "$out/rclone"
chmod 755 "$out/rclone"
lipo "$out/rclone" -verify_arch arm64 x86_64
codesign --force --sign - "$out/rclone"
"$out/rclone" version | grep -F "rclone v$version"
