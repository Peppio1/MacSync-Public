#!/usr/bin/env bash
# A test-only arm64 binary compiled from the EXACT MacSyncRename backend.
# The production bundling script and helper are never modified or replaced.
set -euo pipefail
umask 077
out="${1:?output directory}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
assets="$(cd "$(dirname "$0")/../.." && pwd)/Packaging/RcloneSMBRename"
diagnostics="$(cd "$(dirname "$0")/../.." && pwd)/Tools/SMBDiagnostics"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macsync-diagnostic-go.XXXXXX")"
trap 'rm -rf "$work"' EXIT
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
mkdir -p cmd/macsync-smb-rename-diagnostic
cp "$diagnostics/diagnostic_main.go" cmd/macsync-smb-rename-diagnostic/main.go
cp "$assets/macsync_rename.go" backend/smb/macsync_rename.go
# Test-only: split a single generic rejection into two diagnostic categories.
# The actual predicates, SMB calls and fail-closed behavior are unchanged.
python3 - backend/smb/macsync_rename.go <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
data = file.read_text()
old = '''if !request.IsDirectory && (info.Size() != request.Size ||
\t\t\t!info.ModTime().Equal(time.Unix(request.ModifiedSeconds, request.ModifiedNanos))) {
\t\t\treturn errors.New("source metadata changed")
\t\t}'''
new = '''if !request.IsDirectory && info.Size() != request.Size {
\t\t\treturn errors.New("source size mismatch")
\t\t}
\t\tif !request.IsDirectory && !info.ModTime().Equal(time.Unix(request.ModifiedSeconds, request.ModifiedNanos)) {
\t\t\treturn errors.New("source modified timestamp mismatch")
\t\t}'''
assert data.count(old) == 1, "Only the pinned helper comparison may be instrumented"
file.write_text(data.replace(old, new))
PY
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -tags macsync_ci -trimpath -buildvcs=false \
    -o "$out/rclone-smb-rename-diagnostic" ./cmd/macsync-smb-rename-diagnostic
codesign --force --sign - "$out/rclone-smb-rename-diagnostic"
result=0
"$out/rclone-smb-rename-diagnostic" </dev/null || result=$?
test "$result" -eq 2
