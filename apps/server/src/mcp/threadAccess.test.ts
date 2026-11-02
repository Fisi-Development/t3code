import { expect, it } from "@effect/vitest";
import {
  EnvironmentId,
  ProviderInstanceId,
  ThreadId,
  RunId,
  type OrchestrationV2Run,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { OrchestratorProjectionError } from "../orchestration-v2/Orchestrator.ts";
import * as ThreadManagement from "../orchestration-v2/ThreadManagementService.ts";
import { idleThreadProjection, liveThreadShell } from "./McpToolAccess.testkit.ts";
import { assertLiveCaller } from "./threadAccess.ts";
import type { McpInvocationScope } from "./McpInvocationContext.ts";

it.effect(
  "reports the denying shell separately from later run evidence and still rejects stale callers",
  () => {
    let unreadable = false;
    let rootPresent = true;
    let diagnosticReads = 0;
    return Effect.gen(function* () {
      const threadId = ThreadId.make("thread:diagnostic");
      const current = ProviderInstanceId.make("codex-current");
      const stale = ProviderInstanceId.make("codex-stale");
      const caller = { ...liveThreadShell(threadId), providerInstanceId: current };
      const scope: McpInvocationScope = {
        environmentId: EnvironmentId.make("environment:test"),
        requestNamespace: "mcp-credential-id",
        thread: { threadId, providerInstanceId: stale, providerSessionId: "mcp-credential-id" },
        client: undefined,
        capabilities: new Set(["orchestration"]),
        issuedAt: 0,
      };
      const threads = yield* ThreadManagement.ThreadManagementService;
      const context = {
        caller,
        scope,
        threads,
        limits: { runtimeMode: caller.runtimeMode, interactionMode: caller.interactionMode },
      };
      const denied = yield* assertLiveCaller(context).pipe(Effect.flip);
      expect(denied.code).toBe("parent_not_active");
      expect(denied.message).toContain('"gate":"threadAccess.assertLiveCaller"');
      expect(denied.message).toContain('"callerProviderInstanceId":"codex-stale"');
      expect(denied.message).toContain('"callerMcpProviderSessionId":"mcp-credential-id"');
      expect(denied.message).toContain('"observedProviderInstanceId":"codex-current"');
      expect(denied.message).toContain('"diagnosticRunRootNodePresent":true');
      expect(denied.message).not.toContain("do-not-expose");
      yield* assertLiveCaller({
        ...context,
        scope: { ...scope, thread: { ...scope.thread!, providerInstanceId: current } },
      });
      expect(diagnosticReads).toBe(1);
      const ended = yield* assertLiveCaller({
        ...context,
        caller: { ...caller, activeRunId: null },
      }).pipe(Effect.flip);
      expect(ended.code).toBe("parent_not_active");
      expect(ended.message).toContain('"observedActiveRunId":null');
      expect(ended.message).toContain('"diagnosticRunRootNodePresent":null');
      expect(diagnosticReads).toBe(1);
      rootPresent = false;
      const missingRoot = yield* assertLiveCaller(context).pipe(Effect.flip);
      expect(missingRoot.code).toBe("parent_not_active");
      expect(missingRoot.message).toContain('"diagnosticRunRootNodePresent":false');
      unreadable = true;
      const failedRead = yield* assertLiveCaller(context).pipe(Effect.flip);
      expect(failedRead.code).toBe("parent_not_active");
      expect(failedRead.message).toContain('"diagnosticRunRead":"failed"');
    }).pipe(
      Effect.provide(
        Layer.mock(ThreadManagement.ThreadManagementService)({
          getThreadRecords: (threadId, _fields, filter) => {
            expect(filter).toEqual({ runIds: [RunId.make("run:mcp-test")] });
            diagnosticReads++;
            return unreadable
              ? Effect.fail(new OrchestratorProjectionError({ threadId, cause: "do-not-expose" }))
              : Effect.succeed({
                  ...idleThreadProjection(liveThreadShell(threadId)),
                  runs: [
                    {
                      id: filter?.runIds?.[0],
                      status: "running",
                      providerInstanceId: ProviderInstanceId.make("codex-current"),
                      rootNodeId: rootPresent ? "node:root" : null,
                      privateValue: "do-not-expose",
                    } as unknown as OrchestrationV2Run,
                  ],
                });
          },
        }),
      ),
    );
  },
);
