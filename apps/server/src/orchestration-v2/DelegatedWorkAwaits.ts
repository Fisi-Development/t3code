import { isOrchestrationV2WorkActive, type ThreadId } from "@t3tools/contracts";
import * as DelegatedWorkAwaits from "@t3tools/provider-core/server/DelegatedWorkAwaits";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as ProjectionStore from "./ProjectionStore.ts";

export const layer = Layer.effect(
  DelegatedWorkAwaits.DelegatedWorkAwaits,
  Effect.gen(function* () {
    const projectionStore = yield* ProjectionStore.ProjectionStoreV2;
    return {
      awaitsDelegatedWork: Effect.fn("DelegatedWorkAwaits.awaitsDelegatedWork")(
        function* (threadId: ThreadId, options: { readonly includeClaimedDeliveries: boolean }) {
          // Settled, delivered tasks are left out in SQL, so a thread with thousands of them stays cheap.
          const { subagents } = yield* projectionStore.getThreadRecords(threadId, ["subagents"], {
            omitSettledSubagents: true,
          });
          return subagents.some(
            (task) =>
              task.origin === "app_owned" &&
              task.completionWake !== "settled_only" &&
              (isOrchestrationV2WorkActive(task.status) ||
                task.completionDelivery?.state === "pending" ||
                (options.includeClaimedDeliveries && task.completionDelivery?.state === "claimed")),
          );
        },
        Effect.catch((cause) =>
          Effect.logDebug("orchestration-v2.delegated-work-awaits-read-failed", { cause }).pipe(
            Effect.as(false),
          ),
        ),
      ),
    };
  }),
);
