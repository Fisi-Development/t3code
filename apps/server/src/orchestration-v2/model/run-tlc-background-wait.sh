#!/bin/sh
# Model-check BackgroundWait.tla with TLC. Exits non-zero unless every run below ends as stated.
#   before <cause>: the pre-change server (Fixed = FALSE) with one session-closing cause must
#     break EveryWaitEnds.
#   before race <name>: the round 2 server (Fixed = TRUE, Carried = FALSE) with one ordering
#     around the notice effect must break EveryWaitEnds with the stated trace length.
#   after: the changed server (Carried = TRUE) with every cause and both races must check
#     completely with no invariant or WaitEndsEventually violation.
#   probe <name>: the after configuration must reach the case the probe names.
# Usage: sh run-tlc-background-wait.sh /path/to/tla2tools.jar
set -u
cd "$(dirname "$0")"
JAR="$1"
INVARIANTS="TypeOK AtMostOneOutcome AtMostOneNotice AtMostOneNote WakeOnlyOnNews NoticeOnlyOnNews EveryWaitEnds"
ALL_CAUSES='{"settle", "idle", "crash", "settings"}'
ALL_RACES='{"replacement", "restart"}'
TMP="$(mktemp -d)"
cp BackgroundWait.tla "$TMP/"
status=0

# name fixed carried events races invariants [property]
run() {
  name="$1"
  {
    printf 'CONSTANTS\n  Fixed = %s\n  Carried = %s\n  Events = %s\n  Races = %s\n' "$2" "$3" "$4" "$5"
    printf 'SPECIFICATION Spec\n'
    for inv in $6; do printf 'INVARIANT %s\n' "$inv"; done
    if [ "${7:-}" != "" ]; then printf 'PROPERTY %s\n' "$7"; fi
  } > "$TMP/$name.cfg"
  (cd "$TMP" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -deadlock \
    -config "$name.cfg" BackgroundWait.tla) > "$TMP/$name.txt" 2>&1
  code=$?
  summary="$(grep -E 'distinct states found' "$TMP/$name.txt" | tail -1)"
  trace="$(grep -c '^State [0-9]*:' "$TMP/$name.txt")"
}

# label invariant [expected trace length]
expect_violation() {
  if grep -q "^Error: Invariant $2 is violated\.\$" "$TMP/$name.txt" &&
    ! grep -Eq '^Error: .*[Pp]arse' "$TMP/$name.txt" &&
    [ "$(grep -c '^Error: Invariant' "$TMP/$name.txt")" -eq 1 ] &&
    { [ "${3:-}" = "" ] || [ "$trace" -eq "$3" ]; }; then
    echo "$1: $2 violated as expected, $trace states in the trace"
  else
    echo "$1: UNEXPECTED (TLC exit $code, trace $trace${3:+, expected $3}), see $TMP/$name.txt"
    grep -E '^Error' "$TMP/$name.txt" | head -5
    status=1
  fi
}

for cause in settle idle crash settings; do
  run "before-$cause" FALSE FALSE "{\"$cause\"}" '{}' "$INVARIANTS"
  expect_violation "before $cause" EveryWaitEnds 4
done

# Round 2 (a66a6f18c2) with each ordering: the counterexamples the change removes.
run before-race-replacement TRUE FALSE "$ALL_CAUSES" '{"replacement"}' "$INVARIANTS"
expect_violation "before race replacement" EveryWaitEnds 7
run before-race-restart TRUE FALSE "$ALL_CAUSES" '{"restart"}' "$INVARIANTS"
expect_violation "before race restart" EveryWaitEnds 6

run after TRUE TRUE "$ALL_CAUSES" "$ALL_RACES" "$INVARIANTS" WaitEndsEventually
if [ "$code" -eq 0 ] && grep -q 'Model checking completed. No error has been found.' "$TMP/after.txt"; then
  echo "after: no violation of any invariant or WaitEndsEventually; $summary"
else
  echo "after: FAILED (TLC exit $code), see $TMP/after.txt"
  sed -n '/^Error/,$p' "$TMP/after.txt" | head -60
  status=1
fi

for probe in NoticeAfterReplacement NoticeAfterRestart StopStandsDown StopAcrossRestart \
  ReplayOnce SettledStillHears FailedTurn RestartContinuation NativeWake; do
  run "probe-$probe" TRUE TRUE "$ALL_CAUSES" "$ALL_RACES" "Probe$probe"
  expect_violation "probe $probe reachable" "Probe$probe"
done

echo "TLC output kept in $TMP"
exit "$status"
