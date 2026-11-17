#!/bin/bash
set -euo pipefail
umask 077
work="$RUNNER_TEMP/macsync-release-signing"
mkdir "$work"
curl --fail --location --silent --show-error --retry 2 \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz" \
  -o "$work/sdk.tar.xz"
(cd "$work" && printf '%s  %s\n' 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c' sdk.tar.xz | shasum -a 256 -c -)
mkdir "$work/sdk"
tar -xJf "$work/sdk.tar.xz" -C "$work/sdk"
sign="$(find "$work/sdk" -type f -path '*/bin/sign_update' -print -quit)"
test -x "$sign"
printf '%s\n' "$sign" > "$work/tool-path"
