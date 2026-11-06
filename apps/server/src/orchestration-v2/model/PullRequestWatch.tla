---------------------------- MODULE PullRequestWatch ----------------------------
(***************************************************************************)
(* The pull request watch as the server evaluates it on each host read.    *)
(* Fixed = FALSE models the evaluator before the wake reliability change,  *)
(* Fixed = TRUE after it. The host may push, rerun checks (seen pending or *)
(* finished between two reads), let a bot edit its summary, acknowledge a  *)
(* review command, move the base branch, and the agent may watch again.    *)
(* Ghost counters count wakes per awaited identity; the invariants say     *)
(* each awaited event wakes at most once and, after a read, at least once. *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Fixed, MaxHead, MaxEdits, MaxRuns, MaxEpisodes

Heads == 1..MaxHead
Runs == 1..MaxRuns
Statuses == {"pending", "success", "failure"}

VARIABLES
    \* host
    head, editVer, ack, status, run, conflict, episode,
    \* persisted watch state
    wHead, wSeenVer, wEditTold, wAck, wFailing, wFailRun, wPassed, wPassTold, wConflict,
    \* ghosts
    editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes,
    failWakes, failEpoch, passWakes, conflictWakes, readDone

host == <<head, editVer, ack, status, run, conflict, episode>>
watch == <<wHead, wSeenVer, wEditTold, wAck, wFailing, wFailRun, wPassed, wPassTold, wConflict>>
ghosts == <<editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes,
            failWakes, failEpoch, passWakes, conflictWakes, readDone>>
vars == <<host, watch, ghosts>>

Init ==
    /\ head = 1 /\ editVer = 0 /\ ack = "none" /\ status = "pending" /\ run = 1
    /\ conflict = FALSE /\ episode = 0
    /\ wHead = 1 /\ wSeenVer = 0 /\ wEditTold = 0 /\ wAck = "none"
    /\ wFailing = FALSE /\ wFailRun = 0 /\ wPassed = FALSE /\ wPassTold = FALSE
    /\ wConflict = FALSE
    /\ editedOn = [h \in Heads |-> FALSE] /\ editWakes = [h \in Heads |-> 0]
    /\ ackTriggerWakes = 0 /\ ackOutcomeWakes = 0
    /\ failWakes = [h \in Heads |-> [r \in Runs |-> 0]]
    /\ failEpoch = [h \in Heads |-> 0]
    /\ passWakes = [h \in Heads |-> [e \in 0..MaxRuns |-> 0]]
    /\ conflictWakes = [e \in 0..MaxEpisodes |-> 0]
    /\ readDone = FALSE

----------------------------------------------------------------------------
\* Host events. Each one makes the last read stale.

BotEdit ==   \* a bot rewrites its summary remark (W1, W2, W3, W12)
    /\ editVer < MaxEdits
    /\ editVer' = editVer + 1
    /\ editedOn' = [editedOn EXCEPT ![head] = TRUE]
    /\ readDone' = FALSE
    /\ UNCHANGED <<head, ack, status, run, conflict, episode, watch,
                   editWakes, ackTriggerWakes, ackOutcomeWakes, failWakes, failEpoch,
                   passWakes, conflictWakes>>

AckTriggered ==   \* CodeRabbit acknowledges the agent's review command (W4, W5)
    /\ ack = "none" /\ ack' = "triggered" /\ readDone' = FALSE
    /\ UNCHANGED <<head, editVer, status, run, conflict, episode, watch,
                   editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes, failWakes,
                   failEpoch, passWakes, conflictWakes>>

AckOutcome ==   \* the acknowledgement is edited to its outcome
    /\ ack = "triggered" /\ ack' = "outcome" /\ readDone' = FALSE
    /\ UNCHANGED <<head, editVer, status, run, conflict, episode, watch,
                   editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes, failWakes,
                   failEpoch, passWakes, conflictWakes>>

Finish ==   \* the running check finishes
    /\ status = "pending" /\ status' \in {"success", "failure"} /\ readDone' = FALSE
    /\ UNCHANGED <<head, editVer, ack, run, conflict, episode, watch,
                   editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes, failWakes,
                   failEpoch, passWakes, conflictWakes>>

Rerun ==   \* a finished check is rerun: a new run, pending (W6, W7, W13)
    /\ status # "pending" /\ run < MaxRuns
    /\ status' = "pending" /\ run' = run + 1 /\ readDone' = FALSE
    /\ UNCHANGED <<head, editVer, ack, conflict, episode, watch,
                   editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes, failWakes,
                   failEpoch, passWakes, conflictWakes>>

FastRerun ==   \* a rerun that starts and finishes between two reads (W9)
    /\ status # "pending" /\ run < MaxRuns
    /\ run' = run + 1 /\ status' \in {"success", "failure"} /\ readDone' = FALSE
    /\ UNCHANGED <<head, editVer, ack, conflict, episode, watch,
                   editedOn, editWakes, ackTriggerWakes, ackOutcomeWakes, failWakes,
                   failEpoch, passWakes, conflictWakes>>

Push ==   \* a new head; checks start again; the push may or may not resolve a conflict
    /\ head < MaxHead /\ run < MaxRuns
    /\ head' = head + 1 /\ status' = "pending" /\ run' = run + 1
    /\ conflict' \in BOOLEAN
    /\ episode' = IF conflict' THEN episode + 1 ELSE episode
    /\ episode' <= MaxEpisodes
    /\ readDone' = FALSE
    /\ UNCHANGED <<editVer, ack, watch, editedOn, editWakes, ackTriggerWakes,
                   ackOutcomeWakes, failWakes, failEpoch, passWakes, conflictWakes>>

BaseMove ==   \* the base branch moves: a clean branch may start conflicting (W8)
    /\ conflict' \in BOOLEAN
    \* A conflict that clears and returns between two reads is one conflict to the watch: a new
    \* episode starts only once a read has seen the branch clean, or on a head the watch has not
    \* read yet.
    /\ episode' = IF conflict' /\ ~conflict /\ (~wConflict \/ head # wHead)
                  THEN episode + 1 ELSE episode
    /\ episode' <= MaxEpisodes
    /\ conflict' # conflict
    /\ readDone' = FALSE
    /\ UNCHANGED <<head, editVer, ack, status, run, watch, editedOn, editWakes,
                   ackTriggerWakes, ackOutcomeWakes, failWakes, failEpoch, passWakes,
                   conflictWakes>>

Rewatch ==   \* unwatch and watch again (W11): check state resumes, remarks restart now
    /\ wSeenVer' = editVer /\ wEditTold' = 0 /\ wAck' = ack
    /\ editedOn' = [h \in Heads |-> FALSE] /\ editWakes' = [h \in Heads |-> 0]
    /\ ackTriggerWakes' = 0
    /\ ackOutcomeWakes' = IF ack = "outcome" THEN 1 ELSE 0
    /\ readDone' = FALSE
    /\ UNCHANGED <<host, wHead, wFailing, wFailRun, wPassed, wPassTold, wConflict,
                   failWakes, failEpoch, passWakes, conflictWakes>>

----------------------------------------------------------------------------
\* One read of the host and the evaluator's decision.

Read ==
    LET moved == head # wHead
        \* remarks
        editNews == editVer > wSeenVer /\ (Fixed => wEditTold # head)
        ackNews == IF Fixed THEN ack = "outcome" /\ wAck # "outcome"
                            ELSE ack # "none" /\ ack # wAck
        \* failures: a new failing name, or (fixed) a new failing run
        failingBefore == wFailing /\ ~moved
        failNews == status = "failure" /\ (~failingBefore \/ (Fixed /\ wFailRun # run))
        \* passes
        passedBefore == wPassed /\ ~moved
        toldPass == wPassTold /\ ~moved /\ ~failNews
        passNews == status = "success" /\ IF Fixed THEN ~toldPass ELSE ~passedBefore
        epoch == failEpoch[head] + (IF failNews THEN 1 ELSE 0)
        \* conflicts: news for a head that was not told, until a clean read
        conflictNews == conflict /\ ~(wConflict /\ ~moved)
    IN
    /\ wHead' = head
    /\ wSeenVer' = editVer
    /\ wEditTold' = IF editNews THEN head ELSE wEditTold
    /\ wAck' = ack
    /\ wFailing' = (status = "failure")
    /\ wFailRun' = run
    /\ wPassed' = (status = "success")
    /\ wPassTold' = IF status = "success" THEN TRUE ELSE toldPass
    /\ wConflict' = conflict
    /\ editWakes' = IF editNews THEN [editWakes EXCEPT ![head] = @ + 1] ELSE editWakes
    /\ ackTriggerWakes' = ackTriggerWakes + (IF ackNews /\ ack = "triggered" THEN 1 ELSE 0)
    /\ ackOutcomeWakes' = ackOutcomeWakes + (IF ackNews /\ ack = "outcome" THEN 1 ELSE 0)
    /\ failWakes' = IF failNews THEN [failWakes EXCEPT ![head][run] = @ + 1] ELSE failWakes
    /\ failEpoch' = [failEpoch EXCEPT ![head] = epoch]
    /\ passWakes' = IF passNews THEN [passWakes EXCEPT ![head][epoch] = @ + 1] ELSE passWakes
    /\ conflictWakes' = IF conflictNews THEN [conflictWakes EXCEPT ![episode] = @ + 1]
                                        ELSE conflictWakes
    /\ readDone' = TRUE
    /\ UNCHANGED <<host, editedOn>>

Next == BotEdit \/ AckTriggered \/ AckOutcome \/ Finish \/ Rerun \/ FastRerun
        \/ Push \/ BaseMove \/ Rewatch \/ Read

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
\* At most one delivery per awaited event.
EditOncePerHead == \A h \in Heads : editWakes[h] <= 1                       \* W1 W2 W3 W12
AckOutcomeOnce == ackOutcomeWakes <= 1                                       \* W5
FailOncePerRun == \A h \in Heads, r \in Runs : failWakes[h][r] <= 1         \* W7
PassOncePerEpoch == \A h \in Heads, e \in 0..MaxRuns : passWakes[h][e] <= 1 \* W6 W13
ConflictOncePerEpisode == \A e \in 0..MaxEpisodes : conflictWakes[e] <= 1   \* W8

\* No wake without news.
NoAckProgressWake == ackTriggerWakes = 0                                     \* W4 W5

\* Every awaited outcome is delivered by the read that sees it.
EditDelivered == readDone /\ editedOn[head] => editWakes[head] >= 1
AckOutcomeDelivered == readDone /\ ack = "outcome" => ackOutcomeWakes = 1
FailDelivered == readDone /\ status = "failure" => failWakes[head][run] >= 1  \* W9
PassDelivered == readDone /\ status = "success" => passWakes[head][failEpoch[head]] >= 1
ConflictDelivered == readDone /\ conflict => conflictWakes[episode] >= 1

=============================================================================
