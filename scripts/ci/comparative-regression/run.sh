#!/bin/bash
set -euo pipefail
: "$COMPARE_SUITE" "$COMPARE_REVISION" "$RUNNER_TEMP"
case "$COMPARE_SUITE" in
  local) filter=MirrorDeletionTests.testComparativeLocalResidualDeletes ;;
  smb) filter=SMBV0192DeletionValidationTests.testComparativeSMBDotDuplicates ;;
  *) exit 2 ;;
esac
log="$RUNNER_TEMP/comparison-$COMPARE_SUITE-$COMPARE_REVISION.log"
result=0
swift test -Xswiftc -warnings-as-errors --filter "$filter" > "$log" 2>&1 || result=$?
cat "$log"
# Require a reached final-state marker and one actually executed test.
test "$(grep -c 'MACSYNC_COMPARE_OBSERVED ' "$log")" -eq 1
grep -E 'Executed 1 test, with [0-9]+ failures? \(' "$log" >/dev/null
if [ "$COMPARE_REVISION" = candidate ]; then
  test "$result" -eq 0
  echo "COMPARATIVE_CANDIDATE_PASS"
elif [ "$COMPARE_REVISION" = baseline ]; then
  if [ "$result" -eq 0 ]; then
    echo "::error::Baseline did not reproduce the defect; do not claim a before/after fix"
    exit 1
  fi
  # Only final-state comparison assertions count as a reproduced defect.
  # Any setup/compile/unexpected thrown error invalidates the run.
  grep 'error:.*MACSYNC_COMPARE_EXPECTATION' "$log" >/dev/null
  if grep 'error:' "$log" | grep -v 'MACSYNC_COMPARE_EXPECTATION' >/dev/null; then
    echo "::error::Unrelated failure; comparison invalid"
    exit 1
  fi
  echo "COMPARATIVE_BASELINE_DEFECT_REPRODUCED"
else
  exit 2
fi
