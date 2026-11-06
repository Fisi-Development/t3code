#!/bin/sh
# Model-check PullRequestWatch.tla: each invariant alone against the pre-fix evaluator
# (Fixed = FALSE), expecting a counterexample for each catalogued defect, then every invariant
# against the fixed evaluator (Fixed = TRUE), expecting none.
# Usage: sh run-tlc.sh /path/to/tla2tools.jar
set -u
cd "$(dirname "$0")"
JAR="$1"
INVARIANTS="EditOncePerHead AckOutcomeOnce FailOncePerRun PassOncePerEpoch ConflictOncePerEpisode NoAckProgressWake EditDelivered AckOutcomeDelivered FailDelivered PassDelivered ConflictDelivered"
TMP="$(mktemp -d)"
cp PullRequestWatch.tla "$TMP/"

cfg() {
  fixed="$1"
  shift
  # The smallest bounds that still allow every catalogued sequence: two edits on one head,
  # a push, a rerun after a failure, and a conflict after a resolving push.
  printf 'CONSTANTS\n  Fixed = %s\n  MaxHead = 2\n  MaxEdits = 2\n  MaxRuns = 3\n  MaxEpisodes = 2\nSPECIFICATION Spec\n' "$fixed"
  for inv in "$@"; do printf 'INVARIANT %s\n' "$inv"; done
}

tlc() {
  (cd "$TMP" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -deadlock -config "$1" PullRequestWatch.tla) > "$TMP/out.txt" 2>&1
}

for inv in $INVARIANTS; do
  cfg FALSE "$inv" > "$TMP/before.cfg"
  tlc before.cfg
  if grep -q "is violated" "$TMP/out.txt"; then
    echo "before $inv: violated, trace length $(grep -c '^State [0-9]*:' "$TMP/out.txt")"
    cp "$TMP/out.txt" "$TMP/before-$inv.txt"
  else
    echo "before $inv: holds, $(grep -E 'distinct states found, 0 states left' "$TMP/out.txt" | tail -1)"
  fi
done

# shellcheck disable=SC2086
cfg TRUE $INVARIANTS > "$TMP/after.cfg"
tlc after.cfg
if grep -q "is violated" "$TMP/out.txt"; then
  echo "after: VIOLATED"
  sed -n '/is violated/,$p' "$TMP/out.txt" | head -80
  echo "traces kept in $TMP"
  exit 1
fi
echo "after: no violation; $(grep -E 'distinct states found, 0 states left' "$TMP/out.txt" | tail -1)"

# One check run by two workflow events.
cp PullRequestCheckRollup.tla "$TMP/"
for fixed in FALSE TRUE; do
  for inv in FailureVisible NoPassWhilePending CancelledIsNotFailure; do
    printf 'CONSTANT Fixed = %s\nSPECIFICATION Spec\nINVARIANT %s\n' "$fixed" "$inv" > "$TMP/rollup.cfg"
    (cd "$TMP" && java -cp "$JAR" tlc2.TLC -workers 1 -deadlock -config rollup.cfg PullRequestCheckRollup.tla) > "$TMP/out.txt" 2>&1
    if grep -q "is violated" "$TMP/out.txt"; then
      echo "rollup Fixed=$fixed $inv: violated, trace length $(grep -c '^State [0-9]*:' "$TMP/out.txt")"
    else
      echo "rollup Fixed=$fixed $inv: holds, $(grep -E 'distinct states found, 0 states left' "$TMP/out.txt" | tail -1)"
    fi
  done
done
echo "counterexample traces kept in $TMP"
