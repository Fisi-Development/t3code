import type { ProviderSessionId, ProviderThreadId, ThreadId } from "@t3tools/contracts";
import * as IdAllocator from "@t3tools/provider-core/server/IdAllocator";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as EventSink from "./EventSink.ts";
import * as ProjectionStore from "./ProjectionStore.ts";

export const removeReleasedBackgroundTasks = Effect.fn("ReleasedBackgroundRoster.remove")(
  function* (input: {
    readonly threadId: ThreadId;
    readonly providerSessionId: ProviderSessionId;
    readonly providerThreadId: ProviderThreadId;
    readonly taskIds: ReadonlyArray<string>;
  }) {
    const projectionStore = yield* ProjectionStore.ProjectionStoreV2;
    const eventSink = yield* EventSink.EventSinkV2;
    const idAllocator = yield* IdAllocator.IdAllocatorV2;
    const taskIds = new Set(input.taskIds);
    for (let attempt = 0; attempt < 3; attempt++) {
      const projection = yield* projectionStore.getThreadRecords(input.threadId, [
        "providerThreads",
      ]);
      const providerThread = projection.providerThreads.find(
        (candidate) => candidate.id === input.providerThreadId,
      );
      const tasks = providerThread?.pendingBackgroundTasks ?? [];
      const remaining = tasks.filter((task) => !taskIds.has(task.taskId));
      if (providerThread === undefined || remaining.length === tasks.length) return;
      const now = yield* DateTime.now;
      const { committed } = yield* eventSink.writeIfProviderThreadUnchanged({
        expected: providerThread,
        events: [
          {
            id: yield* idAllocator.allocate.event({
              threadId: input.threadId,
              providerSessionId: input.providerSessionId,
            }),
            type: "provider-thread.updated",
            threadId: input.threadId,
            driver: providerThread.driver,
            providerInstanceId: providerThread.providerInstanceId,
            occurredAt: now,
            payload: { ...providerThread, pendingBackgroundTasks: remaining, updatedAt: now },
          },
        ],
      });
      if (committed) return;
    }
    yield* Effect.logWarning("orchestration-v2.provider-session-release-roster-conflict", {
      providerSessionId: input.providerSessionId,
      providerThreadId: input.providerThreadId,
    });
  },
);
