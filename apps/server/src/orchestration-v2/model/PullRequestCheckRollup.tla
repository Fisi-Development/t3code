------------------------- MODULE PullRequestCheckRollup -------------------------
(***************************************************************************)
(* One check name run twice on one head by two workflow events (push and  *)
(* pull_request), as GitHub's rollup lists them (W9, upstream #17207).    *)
(* Fixed = FALSE: the reader keeps one run per name, the unfinished one    *)
(* first, else the latest completion. Fixed = TRUE: one run per event,     *)
(* and the row for the name takes the worse status.                        *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Fixed

Events == {"push", "pull_request"}
Statuses == {"pending", "success", "failure", "cancelled"}

VARIABLES status, doneAt, clock

vars == <<status, doneAt, clock>>

Init ==
    /\ status = [e \in Events |-> "pending"]
    /\ doneAt = [e \in Events |-> 0]
    /\ clock = 0

Complete(e) ==
    /\ status[e] = "pending"
    /\ \E s \in Statuses \ {"pending"} : status' = [status EXCEPT ![e] = s]
    /\ clock' = clock + 1
    /\ doneAt' = [doneAt EXCEPT ![e] = clock + 1]

Next == \E e \in Events : Complete(e)

Spec == Init /\ [][Next]_vars

Rank(s) == CASE s = "failure" -> 3 [] s = "pending" -> 2 [] s = "success" -> 1
                [] s = "cancelled" -> 0

\* The single row the reader reports for the check name.
Reported ==
    IF Fixed
    THEN IF Rank(status["push"]) >= Rank(status["pull_request"])
         THEN status["push"] ELSE status["pull_request"]
    ELSE IF \E e \in Events : status[e] = "pending" THEN "pending"
         ELSE IF doneAt["push"] >= doneAt["pull_request"]
              THEN status["push"] ELSE status["pull_request"]

\* A failed independent run is never hidden: the row reads failure.
FailureVisible == (\E e \in Events : status[e] = "failure") => Reported = "failure"

\* The row never reads passed while a run is still going (#17344 still holds).
NoPassWhilePending == (\E e \in Events : status[e] = "pending") => Reported # "success"

\* A run cancelled next to a finished run is not reported as a failure of the check.
CancelledIsNotFailure ==
    (\A e \in Events : status[e] \in {"success", "cancelled"}) /\ (\E e \in Events : status[e] = "success")
        => Reported = "success"

=============================================================================
