#!/usr/bin/env bash
set -uo pipefail
base="$RUNNER_TEMP/macsync-smb-fixture"
mountpoint="$base/mounted"
if [ -d "$mountpoint" ] && /sbin/mount | /usr/bin/grep -F " on $mountpoint (" >/dev/null; then
  /sbin/umount "$mountpoint" >/dev/null 2>&1 || sudo /sbin/umount -f "$mountpoint" >/dev/null 2>&1 || true
fi
prefix="$(brew --prefix 2>/dev/null || true)"
if [ -x "$prefix/bin/smbcontrol" ] && [ -f "$base/smb.conf" ]; then
  sudo "$prefix/bin/smbcontrol" -s "$base/smb.conf" smbd shutdown >/dev/null 2>&1 || true
fi
if [ -f "$base/nsmb-created" ] && [ -f "$HOME/Library/Preferences/nsmb.conf" ]; then
  rm -f "$HOME/Library/Preferences/nsmb.conf"
fi
# Remove only the path that this isolated job created, never arbitrary paths.
if [ -f "$base/share-path" ]; then
  share="$(cat "$base/share-path")"
  case "$share" in
    /private/tmp/macsync-ci-share.??????) rm -rf -- "$share";;
  esac
fi
case "$base" in
  "$RUNNER_TEMP"/macsync-smb-fixture) rm -rf -- "$base";;
esac
echo "Disposable Samba fixture cleanup finished"
