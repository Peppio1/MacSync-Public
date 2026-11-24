#!/bin/bash
set -euo pipefail
umask 077
work="$RUNNER_TEMP/macsync-release-signing"
mkdir "$work"
# Keep the exact official SDK and digest. Use the authenticated GitHub
# release-asset API when available; public CDN requests can return 403.
# Never extract or execute an unverified download.
digest='c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
verify_sdk() {
  (cd "$work" && printf '%s  %s\n' "$digest" sdk.tar.xz | shasum -a 256 -c -)
}
downloaded=0
if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null; then
  for attempt in 1 2 3; do
    rm -f "$work/sdk.tar.xz"
    if gh api -H 'Accept: application/octet-stream' \
       repos/sparkle-project/Sparkle/releases/assets/562081725 > "$work/sdk.tar.xz" &&
       verify_sdk; then
      downloaded=1
      break
    fi
    sleep "$((attempt * 2))"
  done
fi
if [[ "$downloaded" != 1 ]]; then
  rm -f "$work/sdk.tar.xz"
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors --max-time 120 \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz" \
    -o "$work/sdk.tar.xz"
fi
verify_sdk
mkdir "$work/sdk"
tar -xJf "$work/sdk.tar.xz" -C "$work/sdk"
sign="$(find "$work/sdk" -type f -path '*/bin/sign_update' -print -quit)"
test -x "$sign"
printf '%s\n' "$sign" > "$work/tool-path"
