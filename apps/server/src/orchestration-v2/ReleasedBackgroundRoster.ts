import {
  endCancelledTurnItem,
  isBackgroundCapableTurnItemType,
  isNonterminalTurnItemStatus,
} from "./CancelledTurnItem.ts";
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
    readonly endTurnItems?: boolean;
  }) {
    const projectionStore = yield* ProjectionStore.ProjectionStoreV2;
    const eventSink = yield* EventSink.EventSinkV2;
    const idAllocator = yield* IdAllocator.IdAllocatorV2;
    const taskIds = new Set(input.taskIds);
    for (let attempt = 0; attempt < 3; attempt++) {
      const projection = yield* projectionStore.getThreadRecords(input.threadId, [
        "providerThreads",
        "runs",
        "nodes",
        "turnItems",
      ]);
      const providerThread = projection.providerThreads.find(
        (candidate) => candidate.id === input.providerThreadId,
      );
      const tasks = providerThread?.pendingBackgroundTasks ?? [];
      const remaining = tasks.filter((task) => !taskIds.has(task.taskId));
      const now = yield* DateTime.now;
      const itemEvents = [];
      const cancelledNodeIds = new Set<string>();
      if (input.endTurnItems) {
        for (const item of projection.turnItems) {
          if (
            !isBackgroundCapableTurnItemType(item.type) ||
            !isNonterminalTurnItemStatus(item.status) ||
            !taskIds.has(item.nativeItemRef?.nativeId ?? "")
          )
            continue;
          itemEvents.push(
            ...(yield* endCancelledTurnItem({
              item,
              projection,
              now,
              cancelledNodeIds,
              allocateEventId: () =>
                idAllocator.allocate.event({
                  threadId: input.threadId,
                  providerSessionId: input.providerSessionId,
                }),
            })),
          );
        }
      }
      if (providerThread === undefined || remaining.length === tasks.length) {
        if (itemEvents.length > 0) yield* eventSink.write({ events: itemEvents });
        return true;
      }
      const { committed } = yield* eventSink.writeIfProviderThreadUnchanged({
        expected: providerThread,
        events: [
          ...itemEvents,
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
      if (committed) return true;
    }
    yield* Effect.logWarning("orchestration-v2.provider-session-release-roster-conflict", {
      providerSessionId: input.providerSessionId,
      providerThreadId: input.providerThreadId,
    });
    return false;
  },
);
