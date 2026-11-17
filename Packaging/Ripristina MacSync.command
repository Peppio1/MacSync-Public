#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
exec "$here/MacSync.app/Contents/MacOS/MacSyncRecovery" "$here"
