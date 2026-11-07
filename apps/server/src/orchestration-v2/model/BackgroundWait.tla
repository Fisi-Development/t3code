--------------------------- MODULE BackgroundWait ---------------------------
(***************************************************************************)
(* One background command a Claude thread started, and the wait the agent  *)
(* may register on it with t3_background_wait before ending its turn.      *)
(*                                                                         *)
(* The command lives in the provider process, so it ends with the session  *)
(* (backgroundTasksEndWithProcess). The thread's projection keeps a roster *)
(* entry for it; an awaited entry holds the thread Working. The agent      *)
(* learns the outcome from: a native task notification (wake), a system   *)
(* notice the server queues on the thread (notice), the turn that fails    *)
(* with the session (failed), or the restart continuation run             *)
(* (restartNoted). A user Stop or archive ends it by the user's hand.      *)
(*                                                                         *)
(* Abstraction: "delivered" means the outcome is in the thread and starts  *)
(* or joins a run (the notice is queued with queue_after_active). A notice *)
(* the server declines to dispatch because the provider instance is       *)
(* disabled or the runtime mode is above the policy ceiling is out of      *)
(* scope: no run can start on that thread until the user changes it.      *)
(*                                                                         *)
(* Fixed = FALSE is the server before the change: settle detaches any idle *)
(* thread, and every session release clears the roster without a word.    *)
(* Fixed = TRUE: settle refuses while an awaited entry holds the thread;   *)
(* an idle release, a process exit, or a settings change that closes the  *)
(* session with no turn running writes one keyed notice effect and keeps   *)
(* the roster entry until that effect has run.                            *)
(*                                                                         *)
(* Events: the session-closing causes TLC may use, so each can be checked  *)
(* alone against the pre-change server.                                    *)
(*   "settle"   - thread.settle (also sent by clients, not only by a user) *)
(*   "idle"     - idle release: idle timeout or the idle pin expiry        *)
(*   "crash"    - provider process exit or event stream failure           *)
(*   "settings" - runtime mode, workspace, or model/provider change that  *)
(*                closes the session                                       *)
(* Races: orderings the change does not handle, each enabled on its own.   *)
(*   "replacement" - a turn start queued on the thread before the notice   *)
(*                   effect was inserted runs first (the outbox runs one   *)
(*                   thread's effects in insertion order) and attaches a   *)
(*                   new session to the provider thread                    *)
(*   "restart"     - the server restarts after the release and before the  *)
(*                   notice effect has run                                 *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Fixed, Events, Races

ASSUME Fixed \in BOOLEAN
ASSUME Events \subseteq {"settle", "idle", "crash", "settings"}
ASSUME Races \subseteq {"replacement", "restart"}

VARIABLES
  roster,       \* projection roster entry: "none" | "unawaited" | "awaited"
  awaitedEver,  \* the agent registered a wait on the command
  proc,         \* the command itself: "running" | "done" | "killed"
  session,      \* provider session: "live" | "closed"
  turn,         \* "running" | "idle"
  pending,      \* the notice effect is in the outbox and not yet acknowledged
  keyUsed,      \* the notice key for this session lifetime was inserted
  noticeMsg,    \* the notice message (id derived from the key) exists
  replays,      \* times the acknowledged notice effect was executed again
  wakes, notices, failed, restartNoted,
  noteStored,   \* restart recovery stored the work for a later run, no run started
  startQueued,  \* a turn start was queued before the notice effect was inserted
  restarted,
  stopped,      \* the user ended the open wait with Stop or archive
  archived,
  settled,
  replaced      \* a replacement session owns the provider thread

vars == <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, replays,
          wakes, notices, failed, restartNoted, noteStored, startQueued, restarted,
          stopped, archived, settled, replaced>>

TypeOK ==
  /\ roster \in {"none", "unawaited", "awaited"}
  /\ proc \in {"running", "done", "killed"}
  /\ session \in {"live", "closed"}
  /\ turn \in {"running", "idle"}
  /\ {pending, keyUsed, noticeMsg, awaitedEver, noteStored, startQueued, restarted,
      stopped, archived, settled, replaced} \subseteq BOOLEAN
  /\ {wakes, notices, failed, restartNoted, replays} \subseteq 0..3

\* The agent has just started the command inside a running turn.
Init ==
  /\ roster = "unawaited"
  /\ awaitedEver = FALSE
  /\ proc = "running"
  /\ session = "live"
  /\ turn = "running"
  /\ pending = FALSE /\ keyUsed = FALSE /\ noticeMsg = FALSE /\ replays = 0
  /\ wakes = 0 /\ notices = 0 /\ failed = 0 /\ restartNoted = 0
  /\ noteStored = FALSE /\ startQueued = FALSE /\ restarted = FALSE
  /\ stopped = FALSE /\ archived = FALSE /\ settled = FALSE /\ replaced = FALSE

Open == proc = "running" \/ roster # "none"
\* A Stop or archive after an outcome reached the agent ends that later run, not the wait.
Delivered == wakes + notices + failed + restartNoted

\* t3_background_wait matches the command in the live roster.
Await ==
  /\ turn = "running" /\ session = "live" /\ roster = "unawaited" /\ proc = "running"
  /\ roster' = "awaited"
  /\ awaitedEver' = TRUE
  /\ UNCHANGED <<proc, session, turn, pending, keyUsed, noticeMsg, replays, wakes, notices,
                 failed, restartNoted, noteStored, startQueued, restarted, stopped,
                 archived, settled, replaced>>

EndTurn ==
  /\ turn = "running" /\ session = "live"
  /\ turn' = "idle"
  /\ UNCHANGED <<roster, awaitedEver, proc, session, pending, keyUsed, noticeMsg, replays,
                 wakes, notices, failed, restartNoted, noteStored, startQueued, restarted,
                 stopped, archived, settled, replaced>>

\* The command finishes while its process lives; the provider delivers the task
\* notification and a wake turn follows (also for unawaited commands).
Complete ==
  /\ proc = "running" /\ session = "live"
  /\ proc' = "done"
  /\ roster' = "none"
  /\ wakes' = wakes + 1
  /\ UNCHANGED <<awaitedEver, session, turn, pending, keyUsed, noticeMsg, replays, notices,
                 failed, restartNoted, noteStored, startQueued, restarted, stopped,
                 archived, settled, replaced>>

\* A user message queues a turn start on the thread before any notice effect.
QueueStart ==
  /\ "replacement" \in Races
  /\ ~startQueued /\ ~keyUsed /\ ~archived
  /\ startQueued' = TRUE
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg,
                 replays, wakes, notices, failed, restartNoted, noteStored, restarted,
                 stopped, archived, settled, replaced>>

\* The release writes a notice instead of clearing the roster. A turn that dies
\* with its session already fails with the reason, so it gets no notice.
Notifies(cause) ==
  /\ Fixed
  /\ cause \in {"idle", "crash", "settings"}
  /\ roster = "awaited"
  /\ turn = "idle"

\* Closing the session ends the process and the command with it; a running turn
\* fails with the reason (outcome for an open wait).
Release(cause) ==
  /\ session = "live"
  /\ session' = "closed"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ IF Notifies(cause)
       THEN /\ pending' = (pending \/ ~keyUsed)  \* the insert is keyed: a retry is a no-op
            /\ keyUsed' = TRUE
            /\ UNCHANGED roster
       ELSE /\ roster' = "none"
            /\ UNCHANGED <<pending, keyUsed>>
  /\ failed' = IF turn = "running" /\ roster = "awaited" THEN failed + 1 ELSE failed
  /\ turn' = "idle"
  /\ settled' = (settled \/ cause = "settle")
  /\ UNCHANGED <<awaitedEver, noticeMsg, replays, wakes, notices, restartNoted, noteStored,
                 startQueued, restarted, stopped, archived, replaced>>

IdleRelease == "idle" \in Events /\ turn = "idle" /\ Release("idle")
ProcessExit == "crash" \in Events /\ Release("crash")
SettingsChange == "settings" \in Events /\ Release("settings")
\* Settle rejects running turns; after the change it also rejects an awaited entry.
Settle ==
  /\ "settle" \in Events
  /\ turn = "idle"
  /\ Fixed => roster # "awaited"
  /\ Release("settle")

\* User Stop ends the command; the session stays.
Stop ==
  /\ ~stopped /\ ~archived /\ Open
  /\ stopped' = (Delivered = 0)
  /\ roster' = "none"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, session, pending, keyUsed, noticeMsg, replays, wakes, notices,
                 failed, restartNoted, noteStored, startQueued, restarted, archived,
                 settled, replaced>>

\* Archive detaches the session; it ends a still-open wait by the user's hand.
Archive ==
  /\ ~archived
  /\ archived' = TRUE
  /\ stopped' = (stopped \/ (Open /\ Delivered = 0))
  /\ roster' = "none"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ session' = "closed"
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, pending, keyUsed, noticeMsg, replays, wakes, notices, failed,
                 restartNoted, noteStored, startQueued, restarted, settled, replaced>>

\* Restart recovery clears every roster and records the work on the run. Only a
\* session that was live at shutdown is eligible for the automatic continuation
\* run; otherwise the note waits for a later run.
ServerRestart ==
  /\ ~restarted
  /\ session = "live" \/ ("restart" \in Races /\ pending)
  /\ restarted' = TRUE
  /\ IF session = "live"
       THEN /\ restartNoted' = IF roster = "awaited" THEN restartNoted + 1 ELSE restartNoted
            /\ UNCHANGED noteStored
       ELSE /\ noteStored' = (noteStored \/ roster = "awaited")
            /\ UNCHANGED restartNoted
  /\ roster' = "none"
  /\ session' = "closed"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, pending, keyUsed, noticeMsg, replays, wakes, notices, failed,
                 startQueued, stopped, archived, settled, replaced>>

\* The earlier queued start runs before the notice and attaches a new session to
\* the provider thread.
Replace ==
  /\ startQueued /\ pending /\ ~replaced /\ session = "closed"
  /\ replaced' = TRUE
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg,
                 replays, wakes, notices, failed, restartNoted, noteStored, startQueued,
                 restarted, stopped, archived, settled>>

\* The notice effect's handler, which may run more than once before it is
\* acknowledged: it queues the message (id derived from the key) while the
\* released session still owns the provider thread, the roster names the
\* command, and the thread is not archived or settled.
Sendable ==
  roster = "awaited" /\ ~replaced /\ ~stopped /\ ~archived /\ ~settled

DispatchNotice ==
  /\ pending /\ Sendable /\ ~noticeMsg
  /\ noticeMsg' = TRUE
  /\ notices' = notices + 1
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, replays, wakes,
                 failed, restartNoted, noteStored, startQueued, restarted, stopped,
                 archived, settled, replaced>>

\* Then the handler removes the entry (only for the released session) and the
\* effect is acknowledged.
Acknowledge ==
  /\ pending /\ (noticeMsg \/ ~Sendable)
  /\ pending' = FALSE
  /\ roster' = IF replaced THEN roster ELSE "none"
  /\ UNCHANGED <<awaitedEver, proc, session, turn, keyUsed, noticeMsg, replays, wakes,
                 notices, failed, restartNoted, noteStored, startQueued, restarted, stopped,
                 archived, settled, replaced>>

\* Replay after process loss runs the acknowledged notice effect again.
Replay ==
  /\ keyUsed /\ ~pending /\ replays = 0
  /\ pending' = TRUE
  /\ replays' = 1
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, keyUsed, noticeMsg, wakes, notices,
                 failed, restartNoted, noteStored, startQueued, restarted, stopped,
                 archived, settled, replaced>>

Next ==
  \/ Await \/ EndTurn \/ Complete \/ QueueStart
  \/ IdleRelease \/ ProcessExit \/ SettingsChange \/ Settle
  \/ Stop \/ Archive \/ ServerRestart \/ Replace
  \/ DispatchNotice \/ Acknowledge \/ Replay

\* The effect worker eventually runs a pending effect to acknowledgement.
Spec == Init /\ [][Next]_vars /\ WF_vars(DispatchNotice) /\ WF_vars(Acknowledge)

(* Rule: at most one delivery per awaited event.                                 *)
AtMostOneOutcome == Delivered + (IF stopped THEN 1 ELSE 0) <= 1
AtMostOneNotice == notices <= 1

(* Rule: no wake without news. A wake follows the command's completion; a notice *)
(* follows an awaited command that ended without reporting.                      *)
WakeOnlyOnNews == wakes > 0 => proc = "done"
NoticeOnlyOnNews == notices > 0 => (awaitedEver /\ proc = "killed")

(* Rule: every wait reaches a delivered terminal outcome.                        *)
(* Safety form: once the awaited command can no longer report and no notice      *)
(* effect is owed, the agent has heard, or the user ended the wait.              *)
EveryWaitEnds ==
  (awaitedEver /\ proc # "running" /\ ~pending) => (Delivered > 0 \/ stopped)
(* Liveness form, under the worker fairness in Spec.                             *)
WaitEndsEventually ==
  [](awaitedEver /\ proc # "running" => <>(Delivered > 0 \/ stopped))
=============================================================================
