#!/bin/bash
set -euo pipefail
out="$1"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
assets="$(cd "$(dirname "$0")/RcloneSMBRename" && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macsync-smb-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"
rclone_version=v1.76.0
smb_version=v0.0.0-20260918041005-0c5d69b69701
cache="$(go env GOMODCACHE)"
go mod download "github.com/rclone/rclone@$rclone_version"
cp -R "$cache/github.com/rclone/rclone@$rclone_version" "$work/rclone"
chmod -R u+w "$work/rclone"
cd "$work/rclone"
grep -F "github.com/cloudsoda/go-smb2 $smb_version" go.mod
go mod download github.com/cloudsoda/go-smb2
cp -R "$cache/github.com/cloudsoda/go-smb2@$smb_version" "$work/go-smb2"
chmod -R u+w "$work/go-smb2"
patch -d "$work/go-smb2" -p1 < "$assets/go-smb2-no-replace.patch"
go mod edit -replace "github.com/cloudsoda/go-smb2=$work/go-smb2"
mkdir -p cmd/macsync-smb-rename
cp "$assets/main.go" cmd/macsync-smb-rename/main.go
cp "$assets/macsync_rename.go" backend/smb/macsync_rename.go
for arch in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -buildvcs=false -o "$work/$arch" ./cmd/macsync-smb-rename
done
lipo -create "$work/arm64" "$work/amd64" -output "$out/rclone-smb-rename"
lipo "$out/rclone-smb-rename" -verify_arch arm64 x86_64
codesign --force --sign - "$out/rclone-smb-rename"
result=0
"$out/rclone-smb-rename" </dev/null || result=$?
test "$result" -eq 2
