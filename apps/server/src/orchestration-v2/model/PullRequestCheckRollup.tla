------------------------- MODULE PullRequestCheckRollup -------------------------
(***************************************************************************)
(* One check name run twice on one head by two workflow events (push and  *)
(* pull_request), as GitHub's rollup lists them (#17207). A failed run may *)
(* be rerun and fail again between two reads.                              *)
(* Fixed = FALSE: the reader keeps one run per name, the unfinished one    *)
(* first, else the latest completion. Fixed = TRUE: one run per event,     *)
(* and the row for the name takes the worse status; on a tie it shows the  *)
(* later run when TieLater = TRUE, else the first event's run.             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Fixed, TieLater

Events == {"push", "pull_request"}
Statuses == {"pending", "success", "failure", "cancelled"}
MaxRuns == 2

VARIABLES status, doneAt, runNo, clock

vars == <<status, doneAt, runNo, clock>>

Init ==
    /\ status = [e \in Events |-> "pending"]
    /\ doneAt = [e \in Events |-> 0]
    /\ runNo = [e \in Events |-> 1]
    /\ clock = 0

Complete(e) ==
    /\ status[e] = "pending"
    /\ \E s \in Statuses \ {"pending"} : status' = [status EXCEPT ![e] = s]
    /\ clock' = clock + 1
    /\ doneAt' = [doneAt EXCEPT ![e] = clock + 1]
    /\ UNCHANGED runNo

\* A failed run is rerun and fails again before the next read.
FailAgain(e) ==
    /\ status[e] = "failure" /\ runNo[e] < MaxRuns
    /\ runNo' = [runNo EXCEPT ![e] = @ + 1]
    /\ clock' = clock + 1
    /\ doneAt' = [doneAt EXCEPT ![e] = clock + 1]
    /\ UNCHANGED status

Next == \E e \in Events : Complete(e) \/ FailAgain(e)

Spec == Init /\ [][Next]_vars

Rank(s) == CASE s = "failure" -> 3 [] s = "pending" -> 2 [] s = "success" -> 1
                [] s = "cancelled" -> 0

\* The run the reader's single row for the check stands for.
Shown ==
    IF Fixed
    THEN IF Rank(status["push"]) > Rank(status["pull_request"]) THEN "push"
         ELSE IF Rank(status["pull_request"]) > Rank(status["push"]) THEN "pull_request"
         ELSE IF TieLater /\ doneAt["pull_request"] > doneAt["push"] THEN "pull_request"
         ELSE "push"
    ELSE IF status["push"] = "pending" THEN "push"
         ELSE IF status["pull_request"] = "pending" THEN "pull_request"
         ELSE IF doneAt["push"] >= doneAt["pull_request"] THEN "push" ELSE "pull_request"

Reported == status[Shown]

\* A failed independent run is never hidden: the row reads failure.
FailureVisible == (\E e \in Events : status[e] = "failure") => Reported = "failure"

\* The row never reads passed while a run is still going (#17344 still holds).
NoPassWhilePending == (\E e \in Events : status[e] = "pending") => Reported # "success"

\* A run cancelled next to a finished run is not reported as a failure of the check.
CancelledIsNotFailure ==
    (\A e \in Events : status[e] \in {"success", "cancelled"}) /\ (\E e \in Events : status[e] = "success")
        => Reported = "success"

\* When the row reads failure it stands for the failed run that finished last, so a rerun that
\* fails again changes the run a watch compares and is reported.
ShownFailureIsLatest ==
    Reported = "failure" =>
        \A e \in Events : status[e] = "failure" => doneAt[e] <= doneAt[Shown]

=============================================================================
