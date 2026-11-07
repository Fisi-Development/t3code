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
(* Carried (needs Fixed) is the notice that carries its own work: the      *)
(* effect names the released tasks, so its handler no longer needs the    *)
(* roster to still list them or the released session to still own the    *)
(* provider thread. It stands down only for a user Stop recorded on the   *)
(* provider thread after the release (persisted, so it survives a         *)
(* restart) or an archive, and removes the tasks from the roster whichever *)
(* session owns it. Restart recovery and a later release skip work that a *)
(* pending notice effect already covers.                                  *)
(* Carried = FALSE with Fixed = TRUE is round 2 (commit a66a6f18c2): the   *)
(* handler delivers only while the released session owns the provider     *)
(* thread and the roster still lists the work, and stands down on settle. *)
(*                                                                         *)
(* Not modelled, by choice:                                                *)
(* - One wait. A Stop recorded for an earlier wait is told apart from one  *)
(*   after this release by comparing times; tests cover that, not TLC.     *)
(* - The handler's check and its dispatch are one step. In the server a   *)
(*   Stop can commit between them; that window predates this change.       *)
(* - Stop needs visible work: the command running or listed in the roster. *)
(*   After restart recovery clears the roster nothing is left to Stop, so  *)
(*   the owed notice is the outcome.                                       *)
(*                                                                         *)
(* Events: the session-closing causes TLC may use, so each can be checked  *)
(* alone against the pre-change server.                                    *)
(*   "settle"   - thread.settle (also sent by clients, not only by a user) *)
(*   "idle"     - idle release: idle timeout or the idle pin expiry        *)
(*   "crash"    - provider process exit or event stream failure           *)
(*   "settings" - runtime mode, workspace, or model/provider change that  *)
(*                closes the session                                       *)
(* Races: orderings around the notice effect, each enabled on its own.     *)
(*   "replacement" - a turn start queued on the thread before the notice   *)
(*                   effect was inserted runs first (the outbox runs one   *)
(*                   thread's effects in insertion order) and attaches a   *)
(*                   new session to the provider thread; that session can *)
(*                   itself be released before the first notice has run    *)
(*   "restart"     - the server restarts after the release and before the  *)
(*                   notice effect has run                                 *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Fixed, Carried, Events, Races

ASSUME Fixed \in BOOLEAN /\ Carried \in BOOLEAN /\ (Carried => Fixed)
ASSUME Events \subseteq {"settle", "idle", "crash", "settings"}
ASSUME Races \subseteq {"replacement", "restart"}

VARIABLES
  roster,       \* projection roster entry: "none" | "unawaited" | "awaited"
  awaitedEver,  \* the agent registered a wait on the command
  proc,         \* the command itself: "running" | "done" | "killed"
  session,      \* provider session: "live" | "closed"
  turn,         \* "running" | "idle"
  pending,      \* the first notice effect is in the outbox and not yet acknowledged
  keyUsed,      \* the first session's notice key was inserted
  noticeMsg,    \* the first notice message (id derived from its key) exists
  extra,        \* a second notice effect, keyed on the replacement session, is pending
  extraMsg,     \* the second notice message exists
  replays,      \* times the acknowledged notice effect was executed again
  wakes, notices, failed, restartNoted,
  noteStored,   \* restart recovery stored the work for a later run, no run started
  startQueued,  \* a turn start was queued before the notice effect was inserted
  restarted,
  stopped,      \* ghost: the user ended the open wait with Stop or archive
  stopRecord,   \* the persisted user Stop on the provider thread (survives restart)
  archived,
  settled,
  replaced,     \* a replacement session owns the provider thread
  hist          \* ghost: orderings seen, for the probes

vars == <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, extra,
          extraMsg, replays, wakes, notices, failed, restartNoted, noteStored, startQueued,
          restarted, stopped, stopRecord, archived, settled, replaced, hist>>

TypeOK ==
  /\ roster \in {"none", "unawaited", "awaited"}
  /\ proc \in {"running", "done", "killed"}
  /\ session \in {"live", "closed"}
  /\ turn \in {"running", "idle"}
  /\ {pending, keyUsed, noticeMsg, extra, extraMsg, awaitedEver, noteStored, startQueued,
      restarted, stopped, stopRecord, archived, settled, replaced} \subseteq BOOLEAN
  /\ {wakes, notices, failed, restartNoted, replays} \subseteq 0..3
  /\ hist \subseteq {"restartOwed", "settleOwed", "suppressed", "replacementReleased"}

\* The agent has just started the command inside a running turn.
Init ==
  /\ roster = "unawaited"
  /\ awaitedEver = FALSE
  /\ proc = "running"
  /\ session = "live"
  /\ turn = "running"
  /\ pending = FALSE /\ keyUsed = FALSE /\ noticeMsg = FALSE /\ replays = 0
  /\ extra = FALSE /\ extraMsg = FALSE
  /\ wakes = 0 /\ notices = 0 /\ failed = 0 /\ restartNoted = 0
  /\ noteStored = FALSE /\ startQueued = FALSE /\ restarted = FALSE
  /\ stopped = FALSE /\ stopRecord = FALSE /\ archived = FALSE /\ settled = FALSE
  /\ replaced = FALSE /\ hist = {}

\* Work the user can Stop: the command runs or the roster still lists it.
Open == proc = "running" \/ roster # "none"
\* A notice is owed and not yet written.
Owed == (pending /\ ~noticeMsg) \/ (extra /\ ~extraMsg)
\* A Stop or archive after an outcome reached the agent ends that later run, not the wait.
Delivered == wakes + notices + failed + restartNoted
\* A pending notice effect already names the work.
Covered == Carried /\ pending

\* t3_background_wait matches the command in the live roster.
Await ==
  /\ turn = "running" /\ session = "live" /\ roster = "unawaited" /\ proc = "running"
  /\ roster' = "awaited"
  /\ awaitedEver' = TRUE
  /\ UNCHANGED <<proc, session, turn, pending, keyUsed, noticeMsg, extra, extraMsg, replays,
                 wakes, notices, failed, restartNoted, noteStored, startQueued, restarted,
                 stopped, stopRecord, archived, settled, replaced, hist>>

EndTurn ==
  /\ turn = "running" /\ session = "live"
  /\ turn' = "idle"
  /\ UNCHANGED <<roster, awaitedEver, proc, session, pending, keyUsed, noticeMsg, extra,
                 extraMsg, replays, wakes, notices, failed, restartNoted, noteStored,
                 startQueued, restarted, stopped, stopRecord, archived, settled, replaced,
                 hist>>

\* The command finishes while its process lives; the provider delivers the task
\* notification and a wake turn follows (also for unawaited commands).
Complete ==
  /\ proc = "running" /\ session = "live"
  /\ proc' = "done"
  /\ roster' = "none"
  /\ wakes' = wakes + 1
  /\ UNCHANGED <<awaitedEver, session, turn, pending, keyUsed, noticeMsg, extra, extraMsg,
                 replays, notices, failed, restartNoted, noteStored, startQueued, restarted,
                 stopped, stopRecord, archived, settled, replaced, hist>>

\* A user message queues a turn start on the thread before any notice effect.
QueueStart ==
  /\ "replacement" \in Races
  /\ ~startQueued /\ ~keyUsed /\ ~archived
  /\ startQueued' = TRUE
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, extra,
                 extraMsg, replays, wakes, notices, failed, restartNoted, noteStored,
                 restarted, stopped, stopRecord, archived, settled, replaced, hist>>

\* The release writes a notice instead of clearing the roster. A turn that dies
\* with its session already fails with the reason, so it gets no notice.
Notifies(cause) ==
  /\ Fixed
  /\ cause \in {"idle", "crash", "settings"}
  /\ roster = "awaited"
  /\ turn = "idle"

\* Closing the session ends the process and the command with it; a running turn
\* fails with the reason (outcome for an open wait). The first session's release
\* inserts the first key; a replacement session's release inserts a second key,
\* unless (Carried) the pending first notice already covers the work.
Release(cause) ==
  /\ session = "live"
  /\ session' = "closed"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ IF Notifies(cause)
       THEN IF ~replaced
              THEN /\ pending' = (pending \/ ~keyUsed)  \* the insert is keyed: a retry is a no-op
                   /\ keyUsed' = TRUE
                   /\ UNCHANGED <<roster, extra, hist>>
              ELSE /\ extra' = (extra \/ (~Covered /\ ~extraMsg))
                   /\ hist' = hist \union {"replacementReleased"}
                   /\ UNCHANGED <<roster, pending, keyUsed>>
       ELSE /\ roster' = "none"
            /\ UNCHANGED <<pending, keyUsed, extra, hist>>
  /\ failed' = IF turn = "running" /\ roster = "awaited" THEN failed + 1 ELSE failed
  /\ turn' = "idle"
  /\ settled' = (settled \/ cause = "settle")
  /\ UNCHANGED <<awaitedEver, noticeMsg, extraMsg, replays, wakes, notices, restartNoted,
                 noteStored, startQueued, restarted, stopped, stopRecord, archived, replaced>>

IdleRelease == "idle" \in Events /\ turn = "idle" /\ Release("idle")
ProcessExit == "crash" \in Events /\ Release("crash")
SettingsChange == "settings" \in Events /\ Release("settings")
\* Settle rejects running turns; after the change it also rejects an awaited entry.
Settle ==
  /\ "settle" \in Events
  /\ turn = "idle"
  /\ Fixed => roster # "awaited"
  /\ Release("settle")
\* Settle on a thread whose session is already closed only marks it settled. It
\* is accepted once restart recovery has cleared the roster, notice owed or not.
SettleClosed ==
  /\ "settle" \in Events
  /\ session = "closed" /\ ~settled
  /\ Fixed => roster # "awaited"
  /\ settled' = TRUE
  /\ hist' = IF Owed THEN hist \union {"settleOwed"} ELSE hist
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, extra,
                 extraMsg, replays, wakes, notices, failed, restartNoted, noteStored,
                 startQueued, restarted, stopped, stopRecord, archived, replaced>>

\* User Stop ends the command and clears the roster; the session stays. The
\* roster clear records the Stop on the provider thread.
Stop ==
  /\ ~stopped /\ ~archived /\ Open
  /\ stopped' = (Delivered = 0)
  /\ stopRecord' = TRUE
  /\ roster' = "none"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, session, pending, keyUsed, noticeMsg, extra, extraMsg, replays,
                 wakes, notices, failed, restartNoted, noteStored, startQueued, restarted,
                 archived, settled, replaced, hist>>

\* Archive detaches the session; it ends a still-open wait, or an owed notice,
\* by the user's hand.
Archive ==
  /\ ~archived
  /\ archived' = TRUE
  /\ stopped' = (stopped \/ ((Open \/ Owed) /\ Delivered = 0))
  /\ roster' = "none"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ session' = "closed"
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, pending, keyUsed, noticeMsg, extra, extraMsg, replays, wakes,
                 notices, failed, restartNoted, noteStored, startQueued, restarted,
                 stopRecord, settled, replaced, hist>>

\* Restart recovery clears every roster and records the work on the run. Only a
\* session that was live at shutdown is eligible for the automatic continuation
\* run; otherwise the note waits for a later run. With Carried, it skips work
\* that a pending notice effect already covers.
ServerRestart ==
  /\ ~restarted
  /\ session = "live" \/ ("restart" \in Races /\ pending)
  /\ restarted' = TRUE
  /\ IF session = "live"
       THEN /\ restartNoted' = IF roster = "awaited" /\ ~Covered
                                 THEN restartNoted + 1 ELSE restartNoted
            /\ UNCHANGED noteStored
       ELSE /\ noteStored' = (noteStored \/ (roster = "awaited" /\ ~Covered))
            /\ UNCHANGED restartNoted
  /\ hist' = IF Owed THEN hist \union {"restartOwed"} ELSE hist
  /\ roster' = "none"
  /\ session' = "closed"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, pending, keyUsed, noticeMsg, extra, extraMsg, replays, wakes,
                 notices, failed, startQueued, stopped, stopRecord, archived, settled,
                 replaced>>

\* The earlier queued start runs before the notice and attaches a new session to
\* the provider thread. The model stops at the window before that session's turn
\* is registered as running, where a release of it notifies again.
Replace ==
  /\ startQueued /\ pending /\ ~replaced /\ session = "closed" /\ ~archived
  /\ replaced' = TRUE
  /\ session' = "live"
  /\ UNCHANGED <<roster, awaitedEver, proc, turn, pending, keyUsed, noticeMsg, extra,
                 extraMsg, replays, wakes, notices, failed, restartNoted, noteStored,
                 startQueued, restarted, stopped, stopRecord, archived, settled, hist>>

\* The notice handler, which may run more than once before it is acknowledged,
\* queues the message (id derived from the key) when Sendable.
\* Round 2: the first notice needs the released session to still own the
\* provider thread; both need the roster to name the command and the thread not
\* to be archived or settled.
\* Carried: unless a user Stop was recorded after the release or the thread was
\* archived.
Sendable(first) ==
  IF Carried
    THEN ~stopRecord /\ ~archived
    ELSE roster = "awaited" /\ (first => ~replaced) /\ ~stopped /\ ~archived /\ ~settled

DispatchNotice ==
  /\ pending /\ Sendable(TRUE) /\ ~noticeMsg
  /\ noticeMsg' = TRUE
  /\ notices' = notices + 1
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, extra, extraMsg,
                 replays, wakes, failed, restartNoted, noteStored, startQueued, restarted,
                 stopped, stopRecord, archived, settled, replaced, hist>>

\* Then the handler removes the entry and the effect is acknowledged. Round 2
\* removes it only for the released session; Carried removes the named tasks
\* whichever session owns the provider thread.
Acknowledge ==
  /\ pending /\ (noticeMsg \/ ~Sendable(TRUE))
  /\ pending' = FALSE
  /\ roster' = IF replaced /\ ~Carried THEN roster ELSE "none"
  /\ hist' = IF noticeMsg THEN hist ELSE hist \union {"suppressed"}
  /\ UNCHANGED <<awaitedEver, proc, session, turn, keyUsed, noticeMsg, extra, extraMsg,
                 replays, wakes, notices, failed, restartNoted, noteStored, startQueued,
                 restarted, stopped, stopRecord, archived, settled, replaced>>

\* The second effect runs after the first (one thread's effects run in order).
DispatchExtra ==
  /\ extra /\ ~pending /\ Sendable(FALSE) /\ ~extraMsg
  /\ extraMsg' = TRUE
  /\ notices' = notices + 1
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, extra,
                 replays, wakes, failed, restartNoted, noteStored, startQueued, restarted,
                 stopped, stopRecord, archived, settled, replaced, hist>>

AcknowledgeExtra ==
  /\ extra /\ ~pending /\ (extraMsg \/ ~Sendable(FALSE))
  /\ extra' = FALSE
  /\ roster' = "none"
  /\ UNCHANGED <<awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, extraMsg,
                 replays, wakes, notices, failed, restartNoted, noteStored, startQueued,
                 restarted, stopped, stopRecord, archived, settled, replaced, hist>>

\* Replay after process loss runs the acknowledged first notice effect again.
Replay ==
  /\ keyUsed /\ ~pending /\ replays = 0
  /\ pending' = TRUE
  /\ replays' = 1
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, keyUsed, noticeMsg, extra,
                 extraMsg, wakes, notices, failed, restartNoted, noteStored, startQueued,
                 restarted, stopped, stopRecord, archived, settled, replaced, hist>>

Next ==
  \/ Await \/ EndTurn \/ Complete \/ QueueStart
  \/ IdleRelease \/ ProcessExit \/ SettingsChange \/ Settle \/ SettleClosed
  \/ Stop \/ Archive \/ ServerRestart \/ Replace
  \/ DispatchNotice \/ Acknowledge \/ DispatchExtra \/ AcknowledgeExtra \/ Replay

\* The effect worker eventually runs a pending effect to acknowledgement.
Spec == Init /\ [][Next]_vars
        /\ WF_vars(DispatchNotice) /\ WF_vars(Acknowledge)
        /\ WF_vars(DispatchExtra) /\ WF_vars(AcknowledgeExtra)

(* Rule: at most one delivery per awaited event.                                 *)
AtMostOneOutcome == Delivered + (IF stopped THEN 1 ELSE 0) <= 1
AtMostOneNotice == notices <= 1
(* A restart note, stored or run, never repeats a notice for the same work.       *)
AtMostOneNote == notices + restartNoted + (IF noteStored THEN 1 ELSE 0) <= 1

(* Rule: no wake without news. A wake follows the command's completion; a notice *)
(* follows an awaited command that ended without reporting.                      *)
WakeOnlyOnNews == wakes > 0 => proc = "done"
NoticeOnlyOnNews == notices > 0 => (awaitedEver /\ proc = "killed")

(* Rule: every wait reaches a delivered terminal outcome.                        *)
(* Safety form: once the awaited command can no longer report and no notice      *)
(* effect is owed, the agent has heard, or the user ended the wait.              *)
EveryWaitEnds ==
  (awaitedEver /\ proc # "running" /\ ~pending /\ ~extra) => (Delivered > 0 \/ stopped)
(* Once every notice effect has run, the dead command no longer holds the thread. *)
RosterClearedAfterNotice ==
  (keyUsed /\ ~pending /\ ~extra) => roster = "none"
(* Liveness form, under the worker fairness in Spec.                             *)
WaitEndsEventually ==
  [](awaitedEver /\ proc # "running" => <>(Delivered > 0 \/ stopped))

(* Reachability probes for the after run. Each is checked as an invariant that   *)
(* must be violated, so a passing after run cannot hide an unreachable case.     *)
ProbeNoticeAfterReplacement == ~(replaced /\ notices = 1 /\ ~pending /\ roster = "none")
ProbeReplacementReleasedBeforeNotice ==
  ~("replacementReleased" \in hist /\ notices = 1 /\ ~pending /\ ~extra)
ProbeRestartBeforeNotice == ~("restartOwed" \in hist /\ notices = 1 /\ ~pending)
ProbeSettleBeforeNotice == ~("settleOwed" \in hist /\ notices = 1 /\ ~pending)
ProbeStopStandsDown == ~(keyUsed /\ stopRecord /\ ~restarted /\ ~pending /\ notices = 0)
ProbeStopAcrossRestart == ~(keyUsed /\ stopRecord /\ restarted /\ ~pending /\ notices = 0)
ProbeReplayOnce == ~(replays = 1 /\ ~pending /\ notices = 1)
ProbeReplayAfterStandDown == ~("suppressed" \in hist /\ replays = 1 /\ ~pending)
ProbeFailedTurn == ~(failed = 1)
ProbeRestartContinuation == ~(restartNoted = 1)
ProbeNativeWake == ~(awaitedEver /\ wakes = 1)
=============================================================================
