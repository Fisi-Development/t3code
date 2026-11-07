import { CommandId, MessageId, type ThreadId } from "@t3tools/contracts";
import { backgroundWorkHoldsCompletion } from "@t3tools/shared/orchestrationV2PendingBackgroundWork";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import type { OrchestrationEffectRequestV2 } from "./EffectOutbox.ts";
import { cancelledRosterTaskWork } from "./RestartBackgroundNote.ts";
import { removeReleasedBackgroundTasks } from "./ReleasedBackgroundRoster.ts";
import * as ThreadManagementService from "./ThreadManagementService.ts";

export const deliverReleasedBackgroundWork = Effect.fn("ReleasedBackgroundWork.deliver")(
  function* (input: {
    readonly threadId: ThreadId;
    readonly effectId: string;
    readonly request: Extract<
      OrchestrationEffectRequestV2,
      { readonly type: "background-work.released" }
    >;
  }) {
    const threads = yield* ThreadManagementService.ThreadManagementService;
    const key = input.effectId.slice("effect:".length);
    const messageId = MessageId.make(`message:${key}`);
    const projection = yield* threads.getThreadRecords(
      input.threadId,
      ["providerThreads", "runs", "messages"],
      { messageIds: [messageId] },
    );
    const providerThread = projection.providerThreads.find(
      (candidate) => candidate.id === input.request.providerThreadId,
    );
    const held = input.request.tasks.filter((task) => backgroundWorkHoldsCompletion([task]));
    if (
      held.length > 0 &&
      projection.thread.archivedAt === null &&
      projection.thread.deletedAt === null &&
      (providerThread?.backgroundWorkStoppedAt === undefined ||
        DateTime.toEpochMillis(providerThread.backgroundWorkStoppedAt) <
          DateTime.toEpochMillis(input.request.releasedAt)) &&
      !projection.messages.some((message) => message.id === messageId)
    ) {
      const detail = input.request.detail
        ?.replace(/\.$/, "")
        .replace(/^./, (first) => first.toLowerCase());
      const reason =
        input.request.reason === "idle_timeout"
          ? "its provider session was closed after a long time without activity"
          : input.request.reason === "detached"
            ? `its provider session was closed when the thread changed${detail ? ` (${detail})` : ""}`
            : `the provider process exited unexpectedly${input.request.detail === undefined ? "" : `: ${input.request.detail}`}`;
      const text = [
        `Note: this background work stopped before it reported back, because ${reason}. It will not report on its own, so check its output, then rerun what you still need and wait for its result:`,
        ...held.slice(0, 10).map((task) => {
          const work = cancelledRosterTaskWork(task);
          return `- ${work.kind}: ${work.label}`;
        }),
        ...(held.length > 10 ? [`- and ${held.length - 10} more`] : []),
      ].join("\n");
      yield* threads
        .dispatch({
          type: "message.dispatch",
          commandId: CommandId.make(`command:${key}`),
          threadId: input.threadId,
          messageId,
          text,
          attachments: [],
          notification: {
            source: { kind: "system" },
            outcome: "updated",
            summary: "Background work stopped without a result",
            detail: text,
          },
          dispatchMode: { type: "queue_after_active" },
          createdBy: "agent",
          creationSource: "server",
        })
        .pipe(
          Effect.catchTags({
            ThreadManagementProviderInstanceDisabledError: (error) =>
              Effect.logInfo("orchestration-v2.background-work-released.instance-disabled", {
                threadId: input.threadId,
                projectId: error.projectId,
                instanceId: error.instanceId,
              }),
            OrchestratorRuntimeModeAboveCeilingError: () =>
              Effect.logInfo("orchestration-v2.background-work-released.above-ceiling", {
                threadId: input.threadId,
              }),
          }),
        );
    }
    yield* removeReleasedBackgroundTasks({
      threadId: input.threadId,
      ...input.request,
      taskIds: input.request.tasks.map((task) => task.taskId),
    });
  },
);
