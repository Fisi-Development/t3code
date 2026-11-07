#!/bin/sh
# Model-check BackgroundWait.tla. Before the change (Fixed = FALSE), each session-closing cause
# alone must break EveryWaitEnds; after it (Fixed = TRUE), every cause together must hold every
# invariant. A last run lets a replacement session take the provider thread before the notice
# effect runs, and prints what TLC finds.
# Usage: sh run-tlc-background-wait.sh /path/to/tla2tools.jar
set -u
cd "$(dirname "$0")"
JAR="$1"
INVARIANTS="TypeOK AtMostOneOutcome AtMostOneNotice NoNoticeWithoutNews EveryWaitEnds"
TMP="$(mktemp -d)"
cp BackgroundWait.tla "$TMP/"
status=0

cfg() {
  # fixed, events, replacement race, invariants...
  fixed="$1" events="$2" race="$3"
  shift 3
  printf 'CONSTANTS\n  Fixed = %s\n  Events = %s\n  ReplacementRace = %s\nSPECIFICATION Spec\n' \
    "$fixed" "$events" "$race"
  for inv in "$@"; do printf 'INVARIANT %s\n' "$inv"; done
}

tlc() {
  (cd "$TMP" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -deadlock -config "$1" BackgroundWait.tla) > "$TMP/out.txt" 2>&1
}

states() {
  grep -E 'distinct states found, 0 states left' "$TMP/out.txt" | tail -1
}

for cause in settle idle crash settings; do
  # shellcheck disable=SC2086
  cfg FALSE "{\"$cause\"}" FALSE $INVARIANTS > "$TMP/before.cfg"
  tlc before.cfg
  if grep -q "is violated" "$TMP/out.txt"; then
    echo "before $cause: $(grep 'is violated' "$TMP/out.txt" | head -1 | sed 's/^Error: //'), trace length $(grep -c '^State [0-9]*:' "$TMP/out.txt")"
    cp "$TMP/out.txt" "$TMP/before-$cause.txt"
  else
    echo "before $cause: no violation (expected one); $(states)"
    status=1
  fi
done

# shellcheck disable=SC2086
cfg TRUE '{"settle", "idle", "crash", "settings"}' FALSE $INVARIANTS > "$TMP/after.cfg"
tlc after.cfg
if grep -q "is violated" "$TMP/out.txt"; then
  echo "after: VIOLATED"
  sed -n '/is violated/,$p' "$TMP/out.txt" | head -80
  status=1
else
  echo "after: no violation; $(states)"
fi

# shellcheck disable=SC2086
cfg TRUE '{"settle", "idle", "crash", "settings"}' TRUE $INVARIANTS > "$TMP/race.cfg"
tlc race.cfg
if grep -q "is violated" "$TMP/out.txt"; then
  echo "after, replacement before delivery: $(grep 'is violated' "$TMP/out.txt" | head -1 | sed 's/^Error: //'), trace length $(grep -c '^State [0-9]*:' "$TMP/out.txt")"
  cp "$TMP/out.txt" "$TMP/after-replacement.txt"
else
  echo "after, replacement before delivery: no violation; $(states)"
fi
echo "TLC output kept in $TMP"
exit "$status"
