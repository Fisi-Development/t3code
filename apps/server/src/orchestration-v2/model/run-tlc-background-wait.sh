#!/bin/sh
# Model-check BackgroundWait.tla with TLC. Exits non-zero unless every run below ends as stated.
#   before <cause>: the pre-change server (Fixed = FALSE) with one session-closing cause must
#     break EveryWaitEnds.
#   after: the changed server with every cause and no race must check completely with no
#     invariant or WaitEndsEventually violation.
#   race <name>: the changed server with one known unhandled ordering must still break
#     EveryWaitEnds. These are open defects; once one is fixed, move it into the after run.
# Usage: sh run-tlc-background-wait.sh /path/to/tla2tools.jar
set -u
cd "$(dirname "$0")"
JAR="$1"
INVARIANTS="TypeOK AtMostOneOutcome AtMostOneNotice WakeOnlyOnNews NoticeOnlyOnNews EveryWaitEnds"
ALL_CAUSES='{"settle", "idle", "crash", "settings"}'
TMP="$(mktemp -d)"
cp BackgroundWait.tla "$TMP/"
status=0

# name fixed events races [property]
run() {
  name="$1"
  {
    printf 'CONSTANTS\n  Fixed = %s\n  Events = %s\n  Races = %s\nSPECIFICATION Spec\n' "$2" "$3" "$4"
    for inv in $INVARIANTS; do printf 'INVARIANT %s\n' "$inv"; done
    if [ "${5:-}" != "" ]; then printf 'PROPERTY %s\n' "$5"; fi
  } > "$TMP/$name.cfg"
  (cd "$TMP" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -deadlock \
    -config "$name.cfg" BackgroundWait.tla) > "$TMP/$name.txt" 2>&1
  code=$?
  summary="$(grep -E 'distinct states found' "$TMP/$name.txt" | tail -1)"
}

expect_violation() {
  label="$1"
  if grep -q '^Error: Invariant EveryWaitEnds is violated\.$' "$TMP/$name.txt" &&
    ! grep -Eq '^Error: (Invariant (TypeOK|AtMost|WakeOnly|NoticeOnly)|.*[Pp]arse)' "$TMP/$name.txt"; then
    echo "$label: EveryWaitEnds violated as expected, $(grep -c '^State [0-9]*:' "$TMP/$name.txt") states in the trace"
  else
    echo "$label: UNEXPECTED (TLC exit $code), see $TMP/$name.txt"
    grep -E '^Error' "$TMP/$name.txt" | head -5
    status=1
  fi
}

for cause in settle idle crash settings; do
  run "before-$cause" FALSE "{\"$cause\"}" '{}'
  expect_violation "before $cause"
done

run after TRUE "$ALL_CAUSES" '{}' WaitEndsEventually
if [ "$code" -eq 0 ] && grep -q 'Model checking completed. No error has been found.' "$TMP/after.txt"; then
  echo "after: no violation of any invariant or WaitEndsEventually; $summary"
else
  echo "after: FAILED (TLC exit $code), see $TMP/after.txt"
  sed -n '/^Error/,$p' "$TMP/after.txt" | head -60
  status=1
fi

for race in replacement restart; do
  run "race-$race" TRUE "$ALL_CAUSES" "{\"$race\"}"
  expect_violation "race $race (open defect)"
done

echo "TLC output kept in $TMP"
exit "$status"
