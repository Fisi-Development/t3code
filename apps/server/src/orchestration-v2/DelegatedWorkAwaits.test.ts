import { assert, it } from "@effect/vitest";
import {
  NodeId,
  ProviderDriverKind,
  ProviderInstanceId,
  ThreadId,
  type OrchestrationV2Subagent,
} from "@t3tools/contracts";
import * as DelegatedWorkAwaits from "@t3tools/provider-core/server/DelegatedWorkAwaits";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as ServerDelegatedWorkAwaits from "./DelegatedWorkAwaits.ts";
import * as ProjectionStore from "./ProjectionStore.ts";

it.effect("D7_waits_only_for_delegated_tasks_that_will_wake_the_parent", () =>
  Effect.gen(function* () {
    const threadId = ThreadId.make("parent");
    const now = yield* DateTime.now;
    const base: OrchestrationV2Subagent = {
      id: NodeId.make("task"),
      threadId,
      runId: null,
      parentNodeId: NodeId.make("root"),
      origin: "app_owned",
      createdBy: "agent",
      driver: ProviderDriverKind.make("codex"),
      providerInstanceId: ProviderInstanceId.make("codex"),
      providerThreadId: null,
      childThreadId: ThreadId.make("child"),
      nativeTaskRef: null,
      prompt: "work",
      title: null,
      model: null,
      status: "running",
      result: null,
      startedAt: now,
      completedAt: null,
      updatedAt: now,
    };
    const cases: ReadonlyArray<{
      label: string;
      task: OrchestrationV2Subagent;
      expected: boolean;
    }> = [
      { label: "running async task", task: base, expected: true },
      {
        label: "terminal with pending delivery",
        task: {
          ...base,
          status: "completed",
          completionDelivery: { state: "pending", observedByRunId: null },
        },
        expected: true,
      },
      {
        label: "terminal with claimed delivery",
        task: {
          ...base,
          status: "completed",
          completionDelivery: { state: "claimed", observedByRunId: null },
        },
        expected: true,
      },
      {
        label: "terminal delivered",
        task: {
          ...base,
          status: "completed",
          completionDelivery: { state: "delivered", observedByRunId: null },
        },
        expected: false,
      },
      {
        label: "settled_only running",
        task: { ...base, completionWake: "settled_only" },
        expected: false,
      },
      { label: "native child", task: { ...base, origin: "provider_native" }, expected: false },
    ];
    for (const { label, task, expected } of cases) {
      const result = yield* Effect.gen(function* () {
        return yield* (yield* DelegatedWorkAwaits.DelegatedWorkAwaits).awaitsDelegatedWork(
          threadId,
        );
      }).pipe(
        Effect.provide(
          ServerDelegatedWorkAwaits.layer.pipe(
            Layer.provide(
              Layer.mock(ProjectionStore.ProjectionStoreV2)({
                getThreadRecords: (requestedThreadId, fields) => {
                  assert.equal(requestedThreadId, threadId);
                  assert.deepEqual<ReadonlyArray<string>>(fields, ["subagents"]);
                  return Effect.succeed({ subagents: [task] } as never);
                },
              }),
            ),
          ),
        ),
      );
      assert.equal(result, expected, label);
    }
  }),
);
