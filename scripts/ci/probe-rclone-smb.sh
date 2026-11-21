#!/usr/bin/env bash
# Probe Rclone's actual SMB backend against the disposable server. No
# password, command line with secret, or rclone config may reach CI artifacts.
set -euo pipefail
umask 077
: "${RUNNER_TEMP:?}" "${MACSYNC_TEST_RCLONE:?}" "${MACSYNC_TEST_SMB_PASSWORD:?}"
: "${MACSYNC_TEST_SMB_USER:?}" "${MACSYNC_TEST_SMB_SHARE:?}" "${MACSYNC_TEST_SMB_HOST:?}"
base="$RUNNER_TEMP/macsync-smb-fixture"
test -f "$base/smb.conf"
test -x "$MACSYNC_TEST_RCLONE"
obscured="$("$MACSYNC_TEST_RCLONE" obscure "$MACSYNC_TEST_SMB_PASSWORD")"
config="$base/ci-direct-smb.conf"
cat > "$config" <<EOF
[macsync-ci-probe]
type = smb
host = $MACSYNC_TEST_SMB_HOST
port = 445
user = $MACSYNC_TEST_SMB_USER
pass = $obscured
domain =
EOF
chmod 600 "$config"
# Run without --verbose or shell tracing: a failure is reported only as an
# exit status; any raw backend diagnostic remains in a disposable local file.
if "$MACSYNC_TEST_RCLONE" --config "$config" lsf "macsync-ci-probe:$MACSYNC_TEST_SMB_SHARE" \
    >/dev/null 2>"$base/rclone-smb-probe.stderr"; then
  echo "MACSYNC_SMB_PROTOCOL direct_rclone_auth_and_list=ok"
else
  echo "::error::Pinned Rclone SMB backend could not authenticate and list the disposable share"
  exit 1
fi
