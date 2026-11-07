--------------------------- MODULE BackgroundWait ---------------------------
(***************************************************************************)
(* One background command a Claude thread started, and the wait the agent  *)
(* may register on it with t3_background_wait before ending its turn.      *)
(*                                                                         *)
(* The command lives in the provider process, so it ends with the session  *)
(* (backgroundTasksEndWithProcess). The thread's projection keeps a roster *)
(* entry for it; an awaited entry holds the thread Working. The agent      *)
(* learns the outcome only from: a native task notification (wake), a      *)
(* system notice written by the server (notice), a failed turn carrying    *)
(* the reason (failed), or the restart continuation note (restartNoted).   *)
(* A user Stop or archive ends the wait by the user's hand (stopped).      *)
(*                                                                         *)
(* Fixed = FALSE is the server before the change: settle detaches any idle *)
(* thread, and every session release clears the roster without a word.    *)
(* Fixed = TRUE: settle refuses while an awaited entry holds the thread;   *)
(* an idle release, a process exit, or a settings change that closes the  *)
(* session writes one keyed notice effect and keeps the roster entry until *)
(* the notice is delivered.                                                *)
(*                                                                         *)
(* Events is the set of session-closing causes TLC may use, so each cause  *)
(* can be checked alone against the pre-change server:                     *)
(*   "settle"   - thread.settle (also sent by clients, not only by a user) *)
(*   "idle"     - idle release: idle timeout or the idle pin expiry        *)
(*   "crash"    - provider process exit or event stream failure           *)
(*   "settings" - runtime mode, workspace, or model/provider change that  *)
(*                closes the session                                       *)
(* ReplacementRace = TRUE lets a new session take over the provider thread *)
(* (and report its own empty roster) after the release but before the      *)
(* notice effect runs.                                                     *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Fixed, Events, ReplacementRace

ASSUME Fixed \in BOOLEAN /\ ReplacementRace \in BOOLEAN
ASSUME Events \subseteq {"settle", "idle", "crash", "settings"}

VARIABLES
  roster,       \* projection roster entry: "none" | "unawaited" | "awaited"
  awaitedEver,  \* the agent registered a wait on the command
  proc,         \* the command itself: "running" | "done" | "killed"
  session,      \* provider session: "live" | "closed"
  turn,         \* "running" | "idle"
  pending,      \* a notice effect sits in the outbox
  keyUsed,      \* the notice key for this session lifetime was inserted
  noticeMsg,    \* the notice message (id derived from the key) exists
  replays,      \* times the completed notice effect was executed again
  wakes, notices, failed, restartNoted,
  stopped,      \* user Stop or archive
  settled,
  replaced      \* a replacement session owns the provider thread

vars == <<roster, awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg,
          replays, wakes, notices, failed, restartNoted, stopped, settled, replaced>>

TypeOK ==
  /\ roster \in {"none", "unawaited", "awaited"}
  /\ proc \in {"running", "done", "killed"}
  /\ session \in {"live", "closed"}
  /\ turn \in {"running", "idle"}
  /\ {pending, keyUsed, noticeMsg, awaitedEver, stopped, settled, replaced} \subseteq BOOLEAN
  /\ {wakes, notices, failed, restartNoted, replays} \subseteq 0..3

\* The agent has just started the command inside a running turn.
Init ==
  /\ roster = "unawaited"
  /\ awaitedEver = FALSE
  /\ proc = "running"
  /\ session = "live"
  /\ turn = "running"
  /\ pending = FALSE
  /\ keyUsed = FALSE
  /\ noticeMsg = FALSE
  /\ replays = 0
  /\ wakes = 0 /\ notices = 0 /\ failed = 0 /\ restartNoted = 0
  /\ stopped = FALSE
  /\ settled = FALSE
  /\ replaced = FALSE

\* t3_background_wait matches the command in the live roster.
Await ==
  /\ turn = "running" /\ session = "live" /\ roster = "unawaited" /\ proc = "running"
  /\ roster' = "awaited"
  /\ awaitedEver' = TRUE
  /\ UNCHANGED <<proc, session, turn, pending, keyUsed, noticeMsg, replays, wakes,
                 notices, failed, restartNoted, stopped, settled, replaced>>

EndTurn ==
  /\ turn = "running" /\ session = "live"
  /\ turn' = "idle"
  /\ UNCHANGED <<roster, awaitedEver, proc, session, pending, keyUsed, noticeMsg, replays,
                 wakes, notices, failed, restartNoted, stopped, settled, replaced>>

\* The command finishes while its process lives; the provider delivers the task
\* notification and a wake turn follows (also for unawaited commands).
Complete ==
  /\ proc = "running" /\ session = "live"
  /\ proc' = "done"
  /\ roster' = "none"
  /\ wakes' = wakes + 1
  /\ UNCHANGED <<awaitedEver, session, turn, pending, keyUsed, noticeMsg, replays,
                 notices, failed, restartNoted, stopped, settled, replaced>>

\* The release writes a notice instead of clearing the roster. A turn that dies
\* with its session already fails with the reason, so it gets no notice.
Notifies(cause) ==
  /\ Fixed
  /\ cause \in {"idle", "crash", "settings"}
  /\ roster = "awaited"
  /\ turn = "idle"

\* Closing the session ends the process and the command with it.
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
  /\ failed' = IF cause = "crash" /\ turn = "running" /\ roster = "awaited"
                THEN failed + 1 ELSE failed
  /\ turn' = "idle"
  /\ settled' = (settled \/ cause = "settle")
  /\ UNCHANGED <<awaitedEver, noticeMsg, replays, wakes, notices, restartNoted, stopped, replaced>>

IdleRelease == "idle" \in Events /\ turn = "idle" /\ Release("idle")
ProcessExit == "crash" \in Events /\ Release("crash")
SettingsChange == "settings" \in Events /\ turn = "idle" /\ Release("settings")
\* Settle rejects running turns; after the change it also rejects an awaited entry.
Settle ==
  /\ "settle" \in Events
  /\ turn = "idle"
  /\ Fixed => roster # "awaited"
  /\ Release("settle")

\* User Stop or archive ends the command by the user's hand.
Stop ==
  /\ ~stopped
  /\ proc = "running" \/ roster # "none"
  /\ stopped' = TRUE
  /\ roster' = "none"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, session, pending, keyUsed, noticeMsg, replays, wakes,
                 notices, failed, restartNoted, settled, replaced>>

\* Restart recovery lists the live session's roster in the continuation note.
\* A session released before the restart is not live; its durable notice effect
\* survives the restart and runs afterwards.
ServerRestart ==
  /\ session = "live"
  /\ session' = "closed"
  /\ proc' = IF proc = "running" THEN "killed" ELSE proc
  /\ restartNoted' = IF roster = "awaited" THEN restartNoted + 1 ELSE restartNoted
  /\ roster' = "none"
  /\ turn' = "idle"
  /\ UNCHANGED <<awaitedEver, pending, keyUsed, noticeMsg, replays, wakes, notices,
                 failed, stopped, settled, replaced>>

\* A new session attaches to the provider thread and reports its own (empty)
\* roster before the notice effect runs.
Replace ==
  /\ ReplacementRace
  /\ session = "closed" /\ ~replaced
  /\ replaced' = TRUE
  /\ roster' = "none"
  /\ UNCHANGED <<awaitedEver, proc, session, turn, pending, keyUsed, noticeMsg, replays,
                 wakes, notices, failed, restartNoted, stopped, settled>>

\* The notice effect runs: one message per key, only while the released session
\* still owns the provider thread and its roster still names the command, and
\* not on an archived or settled thread. Then the entry is removed.
Deliver ==
  /\ pending
  /\ pending' = FALSE
  /\ IF roster = "awaited" /\ ~replaced /\ ~stopped /\ ~settled /\ ~noticeMsg
       THEN /\ notices' = notices + 1
            /\ noticeMsg' = TRUE
       ELSE UNCHANGED <<notices, noticeMsg>>
  /\ roster' = IF replaced THEN roster ELSE "none"
  /\ UNCHANGED <<awaitedEver, proc, session, turn, keyUsed, replays, wakes, failed,
                 restartNoted, stopped, settled, replaced>>

\* Replay after process loss runs the completed notice effect again.
Replay ==
  /\ noticeMsg /\ ~pending /\ replays = 0
  /\ pending' = TRUE
  /\ replays' = 1
  /\ UNCHANGED <<roster, awaitedEver, proc, session, turn, keyUsed, noticeMsg, wakes,
                 notices, failed, restartNoted, stopped, settled, replaced>>

Next ==
  \/ Await \/ EndTurn \/ Complete
  \/ IdleRelease \/ ProcessExit \/ SettingsChange \/ Settle
  \/ Stop \/ ServerRestart \/ Replace \/ Deliver \/ Replay

Spec == Init /\ [][Next]_vars

Delivered == wakes + notices + failed + restartNoted

(* At most one delivery per awaited event: one outcome reaches the agent, and   *)
(* never more than one notice.                                                  *)
AtMostOneOutcome == Delivered + (IF stopped THEN 1 ELSE 0) <= 1
AtMostOneNotice == notices <= 1

(* No wake without news: a notice only for an awaited command that really ended *)
(* without reporting.                                                           *)
NoNoticeWithoutNews == notices > 0 => (awaitedEver /\ proc = "killed")

(* Every wait reaches a delivered outcome: once the awaited command can no longer *)
(* report and no notice is owed, the agent has heard, or the user ended it.     *)
EveryWaitEnds ==
  (awaitedEver /\ proc # "running" /\ ~pending) => (Delivered > 0 \/ stopped)
=============================================================================
