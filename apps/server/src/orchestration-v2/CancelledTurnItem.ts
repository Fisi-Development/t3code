import type {
  EventId,
  OrchestrationV2DomainEvent,
  OrchestrationV2ThreadProjection,
} from "@t3tools/contracts";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import type * as ProjectionStore from "./ProjectionStore.ts";

export function isBackgroundCapableTurnItemType(type: string): boolean {
  return type === "command_execution" || type === "dynamic_tool" || type === "subagent";
}

export function isNonterminalTurnItemStatus(status: string): boolean {
  return status === "pending" || status === "running" || status === "waiting";
}

function resolveStaleBackgroundItemProviderInstanceId(
  item: OrchestrationV2ThreadProjection["turnItems"][number],
  projection: Pick<
    ProjectionStore.ProjectionRuntimeRecoveryState,
    "thread" | "runs" | "providerThreads"
  >,
): OrchestrationV2ThreadProjection["thread"]["providerInstanceId"] {
  if (item.runId !== null) {
    const run = projection.runs.find((candidate) => candidate.id === item.runId);
    if (run !== undefined) {
      return run.providerInstanceId;
    }
  }
  if (item.type === "subagent") {
    return item.providerInstanceId;
  }
  if (item.providerThreadId !== null && item.providerThreadId !== undefined) {
    const providerThread = projection.providerThreads.find(
      (candidate) => candidate.id === item.providerThreadId,
    );
    if (providerThread !== undefined) {
      return providerThread.providerInstanceId;
    }
  }
  return projection.providerThreads[0]?.providerInstanceId ?? projection.thread.providerInstanceId;
}

export const cancelledItem = (
  item: OrchestrationV2ThreadProjection["turnItems"][number],
  now: DateTime.Utc,
): OrchestrationV2ThreadProjection["turnItems"][number] =>
  item.type === "secret_request" && item.secretStatus === "pending"
    ? { ...item, status: "cancelled", secretStatus: "cancelled", completedAt: now, updatedAt: now }
    : {
        ...item,
        ...("streaming" in item ? { streaming: false } : {}),
        status: "cancelled",
        completedAt: now,
        updatedAt: now,
      };

export const endCancelledTurnItem = Effect.fn("CancelledTurnItem.end")(function* <E>(input: {
  readonly item: OrchestrationV2ThreadProjection["turnItems"][number];
  readonly projection: Pick<
    ProjectionStore.ProjectionRuntimeRecoveryState,
    "thread" | "runs" | "providerThreads" | "nodes"
  >;
  readonly now: DateTime.Utc;
  readonly allocateEventId: () => Effect.Effect<EventId, E>;
  readonly cancelledNodeIds: Set<string>;
}) {
  const { item, projection, now, allocateEventId, cancelledNodeIds } = input;
  const events: OrchestrationV2DomainEvent[] = [];
  const providerInstanceId = resolveStaleBackgroundItemProviderInstanceId(item, projection);
  events.push({
    id: yield* allocateEventId(),
    type: "turn-item.updated",
    threadId: projection.thread.id,
    ...(item.runId === null ? {} : { runId: item.runId }),
    ...(item.nodeId === null || item.nodeId === undefined ? {} : { nodeId: item.nodeId }),
    providerInstanceId,
    occurredAt: now,
    payload: cancelledItem(item, now),
  });
  if (item.nodeId !== null && item.nodeId !== undefined) {
    const staleItemNode = projection.nodes.find(
      (candidate) => candidate.id === item.nodeId && isNonterminalTurnItemStatus(candidate.status),
    );
    if (staleItemNode !== undefined && !cancelledNodeIds.has(staleItemNode.id)) {
      cancelledNodeIds.add(staleItemNode.id);
      events.push({
        id: yield* allocateEventId(),
        type: "node.updated",
        threadId: projection.thread.id,
        ...(item.runId === null ? {} : { runId: item.runId }),
        nodeId: staleItemNode.id,
        providerInstanceId,
        occurredAt: now,
        payload: { ...staleItemNode, status: "cancelled", completedAt: now },
      });
    }
  }
  return events;
});
