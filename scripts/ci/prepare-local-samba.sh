#!/usr/bin/env bash
# Disposable macOS-runner SMB fixture. NEVER points at a production server.
set -euo pipefail
umask 077
: "$RUNNER_TEMP" "$GITHUB_ENV"
base="$RUNNER_TEMP/macsync-smb-fixture"
mountpoint="$base/mounted"
share="$base/shared"
user="$(id -un)"
password="MacSyncCI$(openssl rand -hex 14)"
printf '::add-mask::%s\n' "$password"
mkdir -p "$base"/{private,state,cache,lock,pid,logs} "$share" "$mountpoint"
chmod 700 "$base" "$base/private"
chmod 770 "$share"
prefix="$(brew --prefix)"
smbd="$prefix/sbin/samba-dot-org-smbd"
test -x "$smbd"
conf="$base/smb.conf"
cat > "$conf" <<EOF
[global]
    workgroup = WORKGROUP
    server role = standalone server
    security = user
    map to guest = Never
    server min protocol = SMB2_10
    server max protocol = SMB3
    interfaces = 127.0.0.1
    bind interfaces only = yes
    smb ports = 445
    server string = MacSync Disposable CI
    log level = 0
    log file = $base/logs/samba.%m.log
    pid directory = $base/pid
    lock directory = $base/lock
    private dir = $base/private
    state directory = $base/state
    cache directory = $base/cache
    passdb backend = tdbsam:$base/private/passdb.tdb
[MacSyncCI]
    path = $share
    browseable = yes
    read only = no
    valid users = $user
    force user = $user
    create mask = 0660
    directory mask = 0770
EOF
"$prefix/bin/testparm" -s "$conf" > "$base/testparm.log" 2>&1
printf '%s\n%s\n' "$password" "$password" | "$prefix/bin/smbpasswd" -s -a -c "$conf" "$user" > "$base/smbpasswd.log" 2>&1
if nc -z -G 2 127.0.0.1 445 >/dev/null 2>&1; then
  echo "::error::Port 445 already occupied on runner; refusing to touch any existing SMB server"
  exit 1
fi
started="$(date +%s)"
sudo "$smbd" --daemon --configfile="$conf"
ready=0
for attempt in $(seq 1 30); do
  if nc -z -G 2 127.0.0.1 445 >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "::error::Temporary Samba did not listen on loopback TCP/445"
  exit 1
fi
mkdir -p "$HOME/Library/Preferences"
nsmb="$HOME/Library/Preferences/nsmb.conf"
if [ -e "$nsmb" ]; then
  echo "::error::Refusing to overwrite runner SMB client preferences"
  exit 1
fi
printf '[127.0.0.1:%s]\npassword=%s\n' "$user" "$password" > "$nsmb"
chmod 600 "$nsmb"
if ! /sbin/mount_smbfs -N "//$user@127.0.0.1/MacSyncCI" "$mountpoint" > "$base/mount.log" 2>&1; then
  echo "::error::Apple SMB client could not mount the disposable Samba share"
  # Logs are local to runner only. Do not print authentication diagnostics.
  exit 1
fi
fstype="$(/usr/bin/stat -f '%T' "$mountpoint")"
if [ "$fstype" != "smbfs" ]; then
  echo "::error::Expected a genuine macOS smbfs volume, got $fstype"
  exit 1
fi
printf '%s\n' "MacSync SMB CI connected (macOS smbfs, Samba over loopback)"
echo "MACSYNC_TEST_SMB_MOUNT=$mountpoint" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_HOST=127.0.0.1" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_SHARE=MacSyncCI" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_USER=$user" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_PASSWORD=$password" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_ROOT=$base" >> "$GITHUB_ENV"
echo "MACSYNC_SMB_SETUP_SECONDS=$(($(date +%s) - started))"
