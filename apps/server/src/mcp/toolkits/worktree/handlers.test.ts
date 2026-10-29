import * as Commits from "../../../git/DelegateWorktreeCommit.ts";
import { assert, it } from "@effect/vitest";
import { EnvironmentId, ThreadId, ProviderInstanceId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";
import * as McpInvocationContext from "../../McpInvocationContext.ts";
import * as McpToolAccess from "../../McpToolAccess.ts";
import * as McpToolAccessTestkit from "../../McpToolAccess.testkit.ts";
import * as Handlers from "./handlers.ts";
import { WorktreeToolkit } from "./tools.ts";

it.effect("denies direct commit calls from non-delegate threads", () =>
  Effect.gen(function* () {
    const toolkit = yield* WorktreeToolkit.pipe(
      Effect.provide(
        McpToolAccess.HandlersLayer.layer(Handlers.layer).pipe(
          Layer.provide(McpToolAccessTestkit.liveThreadsLayer),
        ),
      ),
    );
    const result = yield* toolkit.handle("t3_worktree_commit", { message: "not allowed" }).pipe(
      Stream.unwrap,
      Stream.runCollect,
      Effect.provideService(McpInvocationContext.McpInvocationContext, {
        environmentId: EnvironmentId.make("env"),
        requestNamespace: "non-delegate",
        capabilities: new Set(["worktree"] as const),
        thread: {
          threadId: ThreadId.make("non-delegate"),
          providerSessionId: "session",
          providerInstanceId: ProviderInstanceId.make("codex"),
        },
        client: undefined,
        issuedAt: 1,
      }),
    );
    const outcome = result[0]?.result;
    assert.equal(
      outcome !== undefined && "code" in outcome ? outcome.code : undefined,
      "capability_denied",
    );
  }).pipe(
    Effect.provide(
      Layer.mergeAll(
        McpToolAccessTestkit.liveThreadsLayer,
        Layer.mock(Commits.DelegateWorktreeCommit)({}),
      ),
    ),
  ),
);
