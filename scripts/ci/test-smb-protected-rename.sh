#!/bin/bash
set -euo pipefail
# No production binaries or credentials. Compile the exact library pin in CI.
: "$RUNNER_TEMP"
version=v0.0.0-20260918041005-0c5d69b69701
assets="$(cd "$(dirname "$0")/smb-protected-rename" && pwd)"
work="$(mktemp -d "$RUNNER_TEMP/macsync-protected-smb.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"
go mod download "github.com/cloudsoda/go-smb2@$version"
cp -R "$(go env GOMODCACHE)/github.com/cloudsoda/go-smb2@$version" "$work/smb2"
chmod -R u+w "$work/smb2"
cd "$work/smb2"
patch -p1 < "$assets/no-replace.patch"
cp "$assets/protected_rename_test.go" macsync_protected_rename_test.go
gofmt -w macsync_protected_rename_test.go
go test -count=1 -timeout=3m -run '^TestMacSyncProtectedRenameFixture$' -v .
