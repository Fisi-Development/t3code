---------------------------- MODULE DelegatedCompletion ----------------------------
(***************************************************************************)
(* A parent waits on one delegated task, T0. Its child may run in this     *)
(* environment or a linked one. The model covers the events that reach     *)
(* the wait: the child's result, a later run the child starts on its own   *)
(* background work, a delivery run cancelled before the provider takes it, *)
(* the linked follower failing, dying on a defect or running out of        *)
(* retries, and a Codex goal that keeps starting turns.                    *)
(*                                                                         *)
(* Fixed = FALSE models upstream main before this change; Fixed = TRUE     *)
(* models it after. Each failure has its own invariant or property.      *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Fixed,        \* the change under test
    Remote,       \* the child runs in a linked environment
    GoalActive,   \* the parent has an active Codex goal
    MaxFollowUps, \* how many times the child may wake itself after its result
    MaxRetries,   \* a finite follower retry schedule
    RunCutAfterTake \* a delivery run can be cancelled after the provider took it (a restart)

VARIABLES
    child,      \* "running" | "resulted"
    wakes,      \* how many follow-up runs the child has started
    lastText,   \* the version of the last result the parent was sent for this child
    pending,    \* delivery messages not yet taken by the parent: set of records
    consumed,   \* what the parent's model saw, in order
    follower,   \* "alive" | "dead" | "done" (linked tasks only)
    retries,    \* failures the follower has retried
    recorded,   \* T0 has its result in this environment
    spins,      \* parent turns started by the goal while T0 was outstanding
    produced    \* the version of the child's latest reply

vars == <<child, wakes, lastText, pending, consumed, follower, retries, recorded, spins, produced>>

\* A delivery: the task it names, the follow-up's original (or "none"), the
\* result version, its generation, and whether it carries news.
Msg(task, of, ver, gen) == [task |-> task, of |-> of, ver |-> ver, gen |-> gen]

Init ==
    /\ child = "running"
    /\ wakes = 0
    /\ lastText = 0
    /\ pending = {}
    /\ consumed = <<>>
    /\ follower = IF Remote THEN "alive" ELSE "done"
    /\ retries = 0
    /\ recorded = FALSE
    /\ spins = 0
    /\ produced = 0

Outstanding == ~\E i \in 1..Len(consumed) : consumed[i].task = "T0"

(* The child's run ends with its result. A local task records it at once;  *)
(* a linked one waits for the follower to read it there.                   *)
ChildFinishes ==
    /\ child = "running"
    /\ child' = "resulted"
    /\ produced' = 1
    /\ IF Remote
         THEN UNCHANGED <<pending, recorded, lastText>>
         ELSE /\ recorded' = TRUE
              /\ lastText' = 1
              /\ pending' = pending \cup {Msg("T0", "none", 1, 1)}
    /\ UNCHANGED <<wakes, consumed, follower, retries, spins>>

(* RemoteDelegation.followOnce sees the run end there and completes T0.     *)
FollowerReads ==
    /\ Remote /\ follower = "alive" /\ child = "resulted" /\ ~recorded
    /\ recorded' = TRUE
    /\ lastText' = 1
    /\ follower' = "done"
    /\ pending' = pending \cup {Msg("T0", "none", 1, 1)}
    /\ UNCHANGED <<child, wakes, consumed, retries, spins, produced>>

(* The other machine asleep or a dropped route: a failure, retried.        *)
FollowerFails ==
    /\ Remote /\ follower = "alive" /\ ~recorded
    /\ IF retries < MaxRetries
         THEN /\ retries' = retries + 1
              /\ UNCHANGED <<follower, pending, recorded, lastText>>
         ELSE \* The retry schedule ended.
              IF Fixed
                THEN \* T0 fails with "stopped following"; version 0 is not a reply.
                     /\ follower' = "gaveUp"
                     /\ recorded' = TRUE
                     /\ pending' = pending \cup {Msg("T0", "none", 0, 1)}
                     /\ UNCHANGED <<retries, lastText>>
                ELSE \* Effect.ignoreCause({ log: true }): logged and dropped.
                     /\ follower' = "dead"
                     /\ UNCHANGED <<retries, pending, recorded, lastText>>
    /\ UNCHANGED <<child, wakes, consumed, spins, produced>>

(* A defect inside a follow attempt. Effect.retry does not retry defects.  *)
FollowerDies ==
    /\ Remote /\ follower = "alive" /\ ~recorded /\ retries < MaxRetries
    /\ IF Fixed
         THEN /\ retries' = retries + 1
              /\ UNCHANGED follower
         ELSE /\ follower' = "dead"
              /\ UNCHANGED retries
    /\ UNCHANGED <<child, wakes, pending, consumed, recorded, lastText, spins, produced>>

(* The child wakes on its own background work after its result and replies *)
(* again, with the same text (sameText) or a revised one. Since upstream    *)
(* #23542 a local child's wake starts a follow-up task Fn that wakes the   *)
(* parent; a linked child's reply after its result reaches no one.        *)
ChildWakesItself(sameText) ==
    /\ recorded /\ child = "resulted" /\ wakes < MaxFollowUps
    /\ wakes' = wakes + 1
    /\ LET ver == IF sameText THEN lastText ELSE lastText + 1
           task == IF wakes' = 1 THEN "F1" ELSE "F2"
       IN /\ produced' = ver
          /\ IF Fixed
               THEN IF sameText
                      THEN UNCHANGED <<pending, lastText>>
                      ELSE /\ pending' = pending \cup {Msg(task, "T0", ver, 1)}
                           /\ lastText' = ver
               ELSE IF Remote
                      \* Nothing follows the thread there once T0 has its result.
                      THEN UNCHANGED <<pending, lastText>>
                      ELSE /\ pending' = pending \cup {Msg(task, "none", ver, 1)}
                           /\ lastText' = ver
    /\ UNCHANGED <<child, consumed, follower, retries, recorded, spins>>

(* A delivery run cancelled before the provider took its input: the cohort *)
(* re-arms it as the next generation (Orchestrator.ts successor wakes).     *)
DeliveryRunCancelled(m) ==
    /\ m \in pending /\ m.gen < 2
    /\ pending' = (pending \ {m}) \cup {[m EXCEPT !.gen = m.gen + 1]}
    /\ UNCHANGED <<child, wakes, lastText, consumed, follower, retries, recorded, spins, produced>>

(* A delivery run cancelled after the provider took its input, for example *)
(* by a server restart. Before the change Orchestrator.ts re-armed every    *)
(* cancelled delivery run; after, only one whose run never started.         *)
CancelledAfterTake(i) ==
    /\ RunCutAfterTake /\ ~Fixed
    /\ consumed[i].gen < 2
    /\ ~\E j \in 1..Len(consumed) :
           consumed[j].task = consumed[i].task /\ consumed[j].gen > consumed[i].gen
    /\ [consumed[i] EXCEPT !.gen = consumed[i].gen + 1] \notin pending
    /\ pending' = pending \cup {[consumed[i] EXCEPT !.gen = consumed[i].gen + 1]}
    /\ UNCHANGED <<child, wakes, lastText, consumed, follower, retries, recorded, spins, produced>>

(* The parent's provider takes the delivery's input.                       *)
ParentTakes(m) ==
    /\ m \in pending
    /\ pending' = pending \ {m}
    /\ consumed' = Append(consumed, m)
    /\ UNCHANGED <<child, wakes, lastText, follower, retries, recorded, spins, produced>>

(* Codex starts another goal turn after the parent's turn ends. Before the  *)
(* change T3 adopts it into the run; after, T3 pauses the goal while the    *)
(* parent waits on delegated work and resumes it with the next turn.        *)
GoalTurn ==
    /\ GoalActive /\ Outstanding /\ pending = {} /\ spins < 3
    /\ ~Fixed
    /\ spins' = spins + 1
    /\ UNCHANGED <<child, wakes, lastText, pending, consumed, follower, retries, recorded, produced>>

Next ==
    \/ ChildFinishes
    \/ FollowerReads
    \/ FollowerFails
    \/ FollowerDies
    \/ \E s \in BOOLEAN : ChildWakesItself(s)
    \/ \E m \in pending : DeliveryRunCancelled(m) \/ ParentTakes(m)
    \/ GoalTurn
    \/ \E i \in 1..Len(consumed) : CancelledAfterTake(i)
    \/ UNCHANGED vars  \* a finished wait stays finished

Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(ChildFinishes)
    /\ WF_vars(FollowerReads)
    /\ \A m \in [task : {"T0", "F1", "F2"}, of : {"T0", "none"}, ver : 0..3, gen : 1..2] :
           WF_vars(ParentTakes(m))

-----------------------------------------------------------------------------
(* Invariants and properties, one per failure.                            *)

\* One delivery per awaited event at the consumer. A re-armed
\* generation replaces a run the provider never took, so the model sees it once.
\* A run cut after the provider answered it (a restart) must not re-arm.
OneWakePerEvent ==
    \A i, j \in 1..Len(consumed) :
        i # j => ~(consumed[i].task = consumed[j].task /\ consumed[i].ver = consumed[j].ver)

\* A wake about this child names the task the parent waits on, or says it
\* is a follow-up of it. An unlabelled follow-up reads as the same completion twice.
WakeNamesAwaitedTask ==
    \A i \in 1..Len(consumed) : consumed[i].task = "T0" \/ consumed[i].of = "T0"

\* No wake without news. A follow-up whose reply repeats the last
\* result the parent was sent does not wake it.
NoWakeWithoutNews ==
    \A i, j \in 1..Len(consumed) :
        i < j => consumed[i].ver # consumed[j].ver

\* No parent turn while it waits on T0 and nothing new arrived.
NoGoalSpin == spins = 0

\* Every wait reaches exactly one delivered terminal outcome.
TerminalDelivered == <>(~Outstanding)

\* The child's latest reply reaches the parent, also when the child
\* replies again after its result in a linked environment.
SeenVersion == IF consumed = <<>> THEN 0
               ELSE LET vs == {consumed[i].ver : i \in 1..Len(consumed)}
                    IN CHOOSE v \in vs : \A w \in vs : v >= w
\* A follower that gave up told the parent where to read the thread there.
LatestReplyDelivered == <>[](SeenVersion = produced \/ follower = "gaveUp")

TypeOK ==
    /\ child \in {"running", "resulted"}
    /\ follower \in {"alive", "dead", "done", "gaveUp"}
    /\ retries \in 0..MaxRetries
=============================================================================
