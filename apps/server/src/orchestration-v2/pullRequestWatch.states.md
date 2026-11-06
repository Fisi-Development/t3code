# Pull request watch: states and events

The watch is evaluated once per read of the host (`evaluatePullRequestWatch`). This table is the
model the evaluator implements; a change to the evaluator starts as a change here. Each row of the
wake suite (`pullRequestWatch.wake.test.ts`) names the case it pins.

Run the suite from the repository root:

```sh
vp test run apps/server/src/orchestration-v2/pullRequestWatch.wake.test.ts packages/source-control-github/src/server/gitHubChecks.wake.test.ts
```

## What a wake is keyed on

| News                             | Identity it is told once for                          | State that remembers it                               |
| -------------------------------- | ----------------------------------------------------- | ----------------------------------------------------- |
| New remark                       | remark id (creation)                                  | `remarksThrough`, `remarkIds`                         |
| Edited remark                    | remark id on the current head                         | `remarkEditsTold`, reset by a new head                |
| Check failed                     | check name, and the run's URL when the host gives one | `failedChecks`, `failedRuns`                          |
| Checks passed                    | the gate's check names on the current head            | `passedChecks`, reset by a new head or a gate failure |
| Late non-required checks settled | names pending when the gate passed                    | `owedChecks`                                          |
| Conflict                         | the current head, until a clean read                  | `conflicting`                                         |
| No checks reported               | the current head                                      | `checksAwaitedSince`                                  |

## Events and transitions

| Event                                                              | Remarks                                                                    | Checks                             | Conflict                           |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------- | ---------------------------------- | ---------------------------------- |
| Read, nothing changed                                              | ignore                                                                     | ignore                             | ignore                             |
| New remark by someone else                                         | wake                                                                       |                                    |                                    |
| Own remark                                                         | ignore                                                                     |                                    |                                    |
| Bot edits a remark, first time on this head                        | wake                                                                       |                                    |                                    |
| Bot edits the same remark again on this head                       | ignore (cursor advances)                                                   |                                    |                                    |
| CodeRabbit "Review triggered." acknowledgement                     | ignore (cursor advances); its later edit wakes once                        |                                    |                                    |
| Check fails (name not failing before)                              |                                                                            | wake                               |                                    |
| Same check fails again after a pending read (retry)                |                                                                            | wake                               |                                    |
| Same check fails again with a new run URL, no pending read seen    |                                                                            | wake                               |                                    |
| Both events' runs failed; either is rerun and fails again (GitHub) |                                                                            | wake (the row shows the later run) |                                    |
| Same failing run read again                                        |                                                                            | ignore                             |                                    |
| Gate passes, not told on this head                                 |                                                                            | wake                               |                                    |
| Gate passes again after a pending read, already told on this head  |                                                                            | ignore                             |                                    |
| Gate passes after a gate failure on this head                      |                                                                            | wake                               |                                    |
| A new required check joins a passing gate                          |                                                                            | wake                               |                                    |
| Advisory check appears or churns with no required checks           |                                                                            | ignore                             |                                    |
| Read failed or returned no checks                                  |                                                                            | keep prior state                   |                                    |
| Host still computing mergeability                                  |                                                                            |                                    | keep prior state                   |
| Branch becomes conflicting, not told on this head                  |                                                                            |                                    | wake                               |
| Push (head moves)                                                  | edits may wake once more                                                   | check news resets                  | an unresolved conflict wakes again |
| Comment-only wakes reach the limit                                 | stop watching, tell the agent                                              |                                    |                                    |
| PR merged or closed                                                | end the watch, tell the agent when closed                                  |                                    |                                    |
| Stop, settle, archive, subagent thread                             | end the watch, no wake                                                     |                                    |                                    |
| Watch again after a stop                                           | check state resumes from the ended watch; remarks restart at the new start |                                    |                                    |
| Server restart                                                     | all of the above is persisted on the watch                                 |                                    |                                    |
| Rate limited                                                       | skip the read, no state change                                             |                                    |                                    |

## Known limits

- A bot that posts a placeholder, then edits it once with its findings, then edits again on the
  same head, wakes for the first edit only. Bots that post findings as new remarks are unaffected.
- A rerun of a check that passed, on the same head, does not wake when it passes again; it wakes
  if it fails.
- Run identity for a failure is the check's URL; a host that gives no URL falls back to the name.
- A conflict that clears and returns between two reads of the same head is one conflict to the
  watch; it was told once and still stands.

## Model

`model/PullRequestWatch.tla` models this table with ghost counters per awaited identity, and
`model/PullRequestCheckRollup.tla` models one check run by two workflow events. `Fixed = FALSE` is
the evaluator before the wake reliability change and `Fixed = TRUE` after it. Check both with TLC:

```sh
sh apps/server/src/orchestration-v2/model/run-tlc.sh /path/to/tla2tools.jar
```
