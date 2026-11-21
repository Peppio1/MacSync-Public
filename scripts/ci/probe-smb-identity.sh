#!/usr/bin/env bash
# Compare metadata from macOS's real smbfs mount to Go SMB2 metadata,
# without modifying the production helper or printing secrets.
set -euo pipefail
umask 077
: "${RUNNER_TEMP:?}" "${GITHUB_WORKSPACE:?}" "${MACSYNC_TEST_SMB_MOUNT:?}"
: "${MACSYNC_TEST_SMB_USER:?}" "${MACSYNC_TEST_SMB_PASSWORD:?}"
test "$MACSYNC_TEST_SMB_HOST" = 127.0.0.1
test "$MACSYNC_TEST_SMB_SHARE" = MacSyncCI
export MACSYNC_TEST_SMB_OBJECT=macsync-ci-metadata-probe.bin
base="$RUNNER_TEMP/macsync-smb-fixture"
path="$MACSYNC_TEST_SMB_MOUNT/$MACSYNC_TEST_SMB_OBJECT"
printf 'synthetic metadata fixture only' > "$path"
trap 'rm -f -- "$path" >/dev/null 2>&1 || true' EXIT
mkdir -p "$base/metadata-probe"
cat > "$base/metadata-probe/go.mod" <<'EOF'
module macsync-ci-smb-metadata
go 1.26.0
require github.com/cloudsoda/go-smb2 v0.0.0-20260918041005-0c5d69b69701
EOF
cp "$GITHUB_WORKSPACE/scripts/ci/probe-smb-identity.go" "$base/metadata-probe/main.go"
client_stats="$(/usr/bin/stat -f '%i %B %m %z' "$path")"
if ! (cd "$base/metadata-probe" && go mod tidy && go build -o "$base/metadata-probe/smb-metadata-probe" .) \
    >"$base/metadata-probe/build.stdout" 2>"$base/metadata-probe/build.stderr"; then
  echo "::error::Synthetic SMB2 metadata probe could not compile (test-only Go module)"
  exit 1
fi
if ! server_stats="$("$base/metadata-probe/smb-metadata-probe" 2>"$base/metadata-probe/probe.stderr")"; then
  echo "::error::Synthetic SMB2 metadata probe could not connect or inspect the file"
  exit 1
fi
read -r client_id client_birth client_modified client_size <<< "$client_stats"
read -r server_id server_birth server_modified server_size <<< "$server_stats"
for number in "$client_id" "$client_birth" "$client_modified" "$client_size" \
              "$server_id" "$server_birth" "$server_modified" "$server_size"; do
  [[ "$number" =~ ^[0-9]+$ ]] || { echo "::error::Malformed synthetic SMB metadata"; exit 1; }
done
eq() { if [ "$1" = "$2" ]; then printf yes; else printf no; fi; }
echo "MACSYNC_SMB_METADATA file_id_equal=$(eq "$client_id" "$server_id") creation_seconds_equal=$(eq "$client_birth" "$server_birth") modified_seconds_equal=$(eq "$client_modified" "$server_modified") size_equal=$(eq "$client_size" "$server_size")"
