#!/usr/bin/env bash
# Disposable macOS-runner SMB fixture. NEVER points at a production server.
set -euo pipefail
umask 077
: "$RUNNER_TEMP" "$GITHUB_ENV"
base="$RUNNER_TEMP/macsync-smb-fixture"
mountpoint="$base/mounted"
# Use a Darwin world-traversable temporary path for the Samba data root.
# macOS runners may deny SMB file access when a share resides under their
# protected GitHub runner work directory despite smbclient access.
share="$(mktemp -d /private/tmp/macsync-ci-share.XXXXXX)"
mkdir -p "$base"/{private,state,cache,lock,pid,logs} "$mountpoint"
printf '%s\n' "$share" > "$base/share-path"
user="$(id -un)"
password="MacSyncCI$(openssl rand -hex 14)"
printf '::add-mask::%s\n' "$password"
chmod 700 "$base" "$base/private"
chmod 770 "$share"
# Seed literal and SFM spellings before the first mount. All names are
# disposable, and every parent contains a known compatible control.
server_parent="macsync-ci-raw"
sfm_dot="$(printf 'Foto12345\357\200\251')"
for parent in macsync-ci-raw macsync-ci-sfm macsync-ci-alias; do
  mkdir -m 770 "$share/$parent"
  mkdir -m 770 "$share/$parent/compatible-control"
done
mkdir -m 770 "$share/macsync-ci-raw/Foto12345."
mkdir -m 770 "$share/macsync-ci-sfm/$sfm_dot" "$share/macsync-ci-sfm/Foto12345-"
printf '%s' 'old raw bytes' > "$share/macsync-ci-raw/Foto12345./child.jpg"
printf '%s' 'old visible bytes' > "$share/macsync-ci-sfm/$sfm_dot/child.jpg"
sfm_space="$(printf 'keep\357\200\250')"
printf '%s' 'ambiguous old bytes' > "$share/macsync-ci-alias/$sfm_space"
printf '%s' 'current bytes' > "$share/macsync-ci-alias/keep"
chmod 660 "$share/macsync-ci-raw/Foto12345./child.jpg" "$share/macsync-ci-sfm/$sfm_dot/child.jpg" "$share/macsync-ci-alias/$sfm_space" "$share/macsync-ci-alias/keep"
# Additional read-only diagnostic fixture: old literal and SFM colon
# spellings plus a corrected name; never use this to authorize ADS removal.
mkdir -m 770 "$share/macsync-ci-colon"
sfm_colon="$(printf 'SFM\357\200\242old')"
mkdir -m 770 "$share/macsync-ci-colon/Raw:old" "$share/macsync-ci-colon/$sfm_colon" "$share/macsync-ci-colon/SFM-old"
printf '%s' 'raw colon bytes' > "$share/macsync-ci-colon/Raw:old/child.jpg"
printf '%s' 'sfm colon bytes' > "$share/macsync-ci-colon/$sfm_colon/child.jpg"
printf '%s' 'corrected bytes' > "$share/macsync-ci-colon/SFM-old/child.jpg"
# Positive exact-duplicate test: SFM-encoded old directory and an
# independently created corrected directory with identical contents.
mkdir -m 770 "$share/macsync-ci-duplicate"
duplicate_colon="$(printf 'Same\357\200\242old')"
mkdir -m 770 "$share/macsync-ci-duplicate/$duplicate_colon" "$share/macsync-ci-duplicate/Same-old"
printf '%s' 'verified same bytes' > "$share/macsync-ci-duplicate/$duplicate_colon/child.jpg"
printf '%s' 'verified same bytes' > "$share/macsync-ci-duplicate/Same-old/child.jpg"
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
    log level = 2
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
    write list = $user
    force user = $user
    # CI diagnostic: use straightforward NT ACL and DOS-attribute mapping.
    # No Samba fruit/AAPL extensions until the basic SMB3 write path passes.
    # This fixture specifically exercises literal server-side names rather
    # than generated DOS aliases for otherwise incompatible spellings.
    mangled names = no
    nt acl support = no
    ea support = no
    store dos attributes = no
    create mask = 0660
    directory mask = 0770
EOF
echo "Validating disposable Samba configuration"
if ! "$prefix/bin/testparm" -s "$conf" > "$base/testparm.log" 2>&1; then
  echo "::error::Samba config invalid"
  tail -n 15 "$base/testparm.log"
  exit 1
fi
echo "Creating ephemeral SMB user (no credential output)"
if ! printf '%s\n%s\n' "$password" "$password" | sudo "$prefix/bin/smbpasswd" -L -s -a -c "$conf" "$user" > "$base/smbpasswd.log" 2>&1; then
  echo "::error::Could not provision ephemeral Samba user"
  tail -n 15 "$base/smbpasswd.log"
  exit 1
fi
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
# Confirm server-side authentication separately from Apple's SMB client.
authfile="$base/smbclient-auth"
printf 'username = %s\npassword = %s\n' "$user" "$password" > "$authfile"
chmod 600 "$authfile"
if ! "$prefix/bin/smbclient" "//127.0.0.1/MacSyncCI" -A "$authfile" -c "ls" > "$base/smbclient.log" 2>&1; then
  echo "::error::Samba-side SMB authentication failed before macOS mount"
  tail -n 8 "$base/smbclient.log" || true
  exit 1
fi
echo "Samba SMB authentication verified"
# Read-only diagnostic through a different SMB client. Only the synthetic
# parent is enumerated; never print auth files or raw server logs.
if "$prefix/bin/smbclient" "//127.0.0.1/MacSyncCI" -A "$authfile" -c "cd $server_parent; ls" > "$base/preexisting-smbclient.log" 2>&1; then
  echo "Direct SMB listing of preexisting synthetic names:"
  cat "$base/preexisting-smbclient.log"
else
  echo "::warning::Direct SMB preexisting parent listing failed"
  tail -n 8 "$base/preexisting-smbclient.log"
fi
if ! "$prefix/bin/smbclient" "//127.0.0.1/MacSyncCI" -A "$authfile" -c "mkdir macsync-ci-probe; rmdir macsync-ci-probe" > "$base/server-write.log" 2>&1; then
  echo "::error::Samba server refuses writes even for its ephemeral SMB account"
  tail -n 10 "$base/server-write.log" || true
  ls -ld "$base" "$share" || true
  exit 1
fi
echo "Server-side SMB write and removal verified"
mkdir -p "$HOME/Library/Preferences"
nsmb="$HOME/Library/Preferences/nsmb.conf"
if [ -e "$nsmb" ]; then
  echo "::error::Refusing to overwrite runner SMB client preferences"
  exit 1
fi
printf '[127.0.0.1:%s]\npassword=%s\n' "$user" "$password" > "$nsmb"
chmod 600 "$nsmb"
: > "$base/nsmb-created"
if ! /sbin/mount_smbfs -f 0666 -d 0777 -N "//$user@127.0.0.1/MacSyncCI" "$mountpoint" > "$base/mount.log" 2>&1; then
  echo "Apple SMB -N did not accept the ephemeral nsmb.conf entry; retrying once with an ephemeral credential"
  # No shell tracing, stdout or stderr from the command; credential is CI-only,
  # masked in GitHub logs and never placed in any repository or artifact.
  if ! /sbin/mount_smbfs -f 0666 -d 0777 "//$user:$password@127.0.0.1/MacSyncCI" "$mountpoint" > "$base/mount2.log" 2>&1; then
    echo "::error::Apple SMB client could not mount the verified disposable share"
    tail -n 10 "$base/mount.log" || true
    tail -n 10 "$base/mount2.log" || true
    exit 1
  fi
fi
# /usr/bin/stat -f %T is NOT a filesystem-type query on Darwin.
# Require the kernel mount table itself to identify the exact mount as smbfs.
if ! /sbin/mount | grep -F " on $mountpoint (smbfs," >/dev/null; then
  echo "::error::Expected a genuine smbfs entry for the disposable mount in the kernel mount table"
  exit 1
fi
if ! mkdir "$mountpoint/macsync-ci-macos-write-probe" > "$base/client-write.log" 2>&1; then
  echo "::error::Genuine macOS smbfs mount has no write permission"
  tail -n 5 "$base/client-write.log" || true
  ls -ld "$share" "$mountpoint" || true
  /sbin/mount | grep -F " on $mountpoint (" || true
  /usr/bin/smbutil statshares -m "$mountpoint" 2>/dev/null | grep -E "SMB_VERSION|SMB_SHARE_TYPE|USER_ID|AUTH|SMB_NEGOTIATE" | head -n 12 || true
  # Filter server diagnostics to server-denial keywords; never upload raw logs.
  grep -Eih "NT_STATUS_ACCESS_DENIED|access denied|Permission denied|mkdir.*failed|create.*failed|denied" "$base"/logs/* 2>/dev/null | tail -n 16 || true
  exit 1
fi
rmdir "$mountpoint/macsync-ci-macos-write-probe"
echo "Client-side macOS smbfs write and removal verified"
printf '%s\n' "MacSync SMB CI connected (macOS smbfs, Samba over loopback)"
echo "MACSYNC_TEST_SMB_MOUNT=$mountpoint" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_HOST=127.0.0.1" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_SHARE=MacSyncCI" >> "$GITHUB_ENV"
echo "MACSYNC_TEST_SMB_ROOT=$base" >> "$GITHUB_ENV"
echo "MACSYNC_SMB_SETUP_SECONDS=$(($(date +%s) - started))"
