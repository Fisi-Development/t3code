#!/bin/sh
# Model-check every configuration: before-* must each report a violation, after-* none.
# Usage: apps/server/src/orchestration-v2/model/check.sh   (needs Java and tla2tools.jar; TLA2TOOLS=path)
cd "$(dirname "$0")" || exit 1
JAR="${TLA2TOOLS:-$HOME/.cache/tla/tla2tools.jar}"
status=0
for cfg in DelegatedCompletion.*.cfg; do
  name=${cfg#DelegatedCompletion.}; name=${name%.cfg}
  out=$(java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -deadlock -cleanup -metadir "${TMPDIR:-/tmp}/tlc-$name" -config "$cfg" DelegatedCompletion.tla 2>&1)
  if printf '%s' "$out" | grep -q -E 'is violated|Temporal properties were violated'; then verdict=violation
  elif printf '%s' "$out" | grep -q 'Model checking completed. No error has been found.'; then verdict=clean
  else verdict=error; fi
  states=$(printf '%s' "$out" | grep -E 'distinct states found' | tail -1)
  bad=$(printf '%s' "$out" | grep -E 'Invariant .* is violated|Temporal properties were violated' | head -1)
  len=$(printf '%s' "$out" | grep -c -E '^State [0-9]+:')
  echo "$name: $verdict ${bad:+($bad, trace $len states)} $states"
  case "$name:$verdict" in before-cut-before-start:clean|before-*:violation|after-*:clean) ;; *) status=1 ;; esac
done
exit $status
