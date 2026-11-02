import type { ProjectionRecordField } from "../orchestration-v2/ProjectionStore.ts";
import {
  CommandId,
  OrchestratorMcpFailure,
  type ProjectId,
  type ProviderInteractionMode,
  type RuntimeMode,
  type ThreadId,
  type OrchestrationV2ThreadShell,
} from "@t3tools/contracts";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

import type { OrchestratorV2Error } from "../orchestration-v2/Orchestrator.ts";
import * as ThreadManagement from "../orchestration-v2/ThreadManagementService.ts";
import * as OrchestrationMcp from "./OrchestratorMcpService.ts";
import * as McpInvocationContext from "./McpInvocationContext.ts";

export const unavailable = () =>
  new OrchestratorMcpFailure({
    code: "orchestration_error",
    message: "The operation could not be completed.",
  });

export const dispatchFailure = (
  error: OrchestratorV2Error | ThreadManagement.ThreadManagementProviderInstanceDisabledError,
) =>
  error._tag === "ThreadManagementProviderInstanceDisabledError"
    ? new OrchestratorMcpFailure({ code: "invalid_request", message: error.message })
    : (error._tag === "OrchestratorDispatchError" ||
          error._tag === "OrchestratorCommandRejectedError") &&
        typeof error.cause === "string" &&
        error.cause.length > 0
      ? new OrchestratorMcpFailure({
          code: "orchestration_error",
          message: Array.from(error.cause).slice(0, 1000).join(""),
        })
      : unavailable();

export interface CallerLimits {
  readonly runtimeMode: RuntimeMode;
  readonly interactionMode: ProviderInteractionMode;
}

export interface Caller {
  readonly scope: McpInvocationContext.McpInvocationScope;
  readonly threads: ThreadManagement.ThreadManagementService["Service"];
  readonly caller: OrchestrationV2ThreadShell | undefined;
  readonly limits: CallerLimits;
}

export const readCaller = Effect.fn("mcp.readCaller")(function* () {
  const scope = yield* McpInvocationContext.McpInvocationContext;
  if (!scope.capabilities.has("orchestration")) {
    return yield* new OrchestratorMcpFailure({
      code: "capability_denied",
      message: "This credential cannot control threads.",
    });
  }
  return yield* loadCaller();
});

export const loadCaller = Effect.fn("mcp.loadCaller")(function* () {
  const scope = yield* McpInvocationContext.McpInvocationContext;
  const threads = yield* ThreadManagement.ThreadManagementService;
  if (scope.thread === undefined) {
    return {
      scope,
      threads,
      caller: undefined,
      limits: {
        runtimeMode: McpInvocationContext.clientRuntimeModeCeiling(scope.client),
        interactionMode: "default",
      },
    } satisfies Caller;
  }
  const caller = yield* threads
    .getThreadShell(scope.thread.threadId)
    .pipe(Effect.mapError(unavailable));
  if (caller === null || caller.deletedAt !== null) {
    return yield* new OrchestratorMcpFailure({
      code: "thread_not_found",
      message: "The calling thread was not found.",
    });
  }
  return {
    scope,
    threads,
    caller,
    limits: { runtimeMode: caller.runtimeMode, interactionMode: caller.interactionMode },
  } satisfies Caller;
});

export const assertTargetWithinLimits = (
  limits: CallerLimits,
  target: { readonly runtimeMode: RuntimeMode; readonly interactionMode: ProviderInteractionMode },
) =>
  OrchestrationMcp.resolveRuntimeMode(limits.runtimeMode, target.runtimeMode).pipe(
    Effect.andThen(
      OrchestrationMcp.resolveInteractionMode(limits.interactionMode, target.interactionMode),
    ),
    Effect.asVoid,
  );

const encodeCallerContext = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));

/**
 * A thread caller acts only while it owns a live run, or a background
 * subagent that run started, of a thread that is not archived, so a provider
 * token that outlived its session cannot act. An OAuth client has no run; its
 * session and ceiling are its authority.
 */
export const assertLiveCaller = Effect.fn("mcp.assertLiveCaller")(function* ({
  caller,
  scope,
  threads,
}: Caller) {
  if (caller === undefined) return;
  if (OrchestrationMcp.isLiveCallerShell(caller, scope.thread?.providerInstanceId)) return;

  // Keep the denying snapshot distinct from this later diagnostic read.
  const records =
    caller.activeRunId === null
      ? null
      : yield* threads
          .getThreadRecords(caller.id, ["runs"], {
            runIds: [caller.activeRunId],
          })
          .pipe(Effect.catchCause(() => Effect.succeed(null)));
  const run = records?.runs.find((candidate) => candidate.id === caller.activeRunId);
  const boundedId = (value: string | null | undefined) => value?.slice(0, 512) ?? null;
  const context = {
    gate: "threadAccess.assertLiveCaller",
    callerProviderInstanceId: boundedId(scope.thread?.providerInstanceId),
    callerMcpProviderSessionId: boundedId(scope.thread?.providerSessionId),
    observedProviderInstanceId: boundedId(caller.providerInstanceId),
    observedActiveRunId: boundedId(caller.activeRunId),
    observedArchived: caller.archivedAt !== null,
    observedOwnedBackgroundSubagent:
      caller.pendingBackgroundTasks?.some(
        (task) =>
          task.kind === "subagent" && task.providerInstanceId === scope.thread?.providerInstanceId,
      ) ?? false,
    diagnosticRunRead:
      caller.activeRunId === null ? "not_needed" : records === null ? "failed" : "later_snapshot",
    diagnosticRunStatus: run?.status ?? null,
    diagnosticRunProviderInstanceId: boundedId(run?.providerInstanceId),
    diagnosticRunRootNodePresent: run === undefined ? null : run.rootNodeId !== null,
  };
  return yield* new OrchestratorMcpFailure({
    code: "parent_not_active",
    message: `The calling provider no longer owns an active thread run. Context: ${encodeCallerContext(context)}`,
  });
});

export const assertFullAccess = (context: Caller, message: string) =>
  context.limits.runtimeMode === "full-access" && context.limits.interactionMode === "default"
    ? Effect.void
    : Effect.fail(new OrchestratorMcpFailure({ code: "capability_denied", message }));

export const resolveProjectId = (context: Caller, projectId: ProjectId | undefined) =>
  projectId !== undefined
    ? Effect.succeed(projectId)
    : context.caller !== undefined
      ? Effect.succeed(context.caller.projectId)
      : Effect.fail(
          new OrchestratorMcpFailure({
            code: "target_required",
            message: "Pass projectId: this MCP client is not running inside a T3 thread.",
          }),
        );

const resolveThreadId = (context: Caller, threadId: ThreadId | undefined) =>
  threadId !== undefined
    ? Effect.succeed(threadId)
    : context.caller !== undefined
      ? Effect.succeed(context.caller.id)
      : Effect.fail(
          new OrchestratorMcpFailure({
            code: "target_required",
            message: "Pass threadId: this MCP client is not running inside a T3 thread.",
          }),
        );

export const readThread = Effect.fn("mcp.readThread")(function* <
  K extends ProjectionRecordField = never,
>(threadId?: ThreadId, fields: ReadonlyArray<K> = []) {
  const context = yield* readCaller();
  const targetId = yield* resolveThreadId(context, threadId);
  const shell = yield* context.threads.getThreadShell(targetId).pipe(Effect.mapError(unavailable));
  if (shell === null || shell.deletedAt !== null) {
    return yield* new OrchestratorMcpFailure({
      code: "thread_not_found",
      message: "The thread was not found.",
    });
  }
  const projection = yield* context.threads
    .getProjectThreadRecords({ projectId: shell.projectId, threadId: targetId }, fields, {
      turnItemTypes: ["user_input_request"],
    })
    .pipe(
      Effect.mapError((error) =>
        error._tag === "ThreadManagementThreadNotFoundError"
          ? new OrchestratorMcpFailure({
              code: "thread_not_found",
              message: "The thread was not found.",
            })
          : unavailable(),
      ),
    );
  return { ...context, projection };
});

export const newCommandId = Effect.fn("mcp.newCommandId")(function* () {
  const crypto = yield* Crypto.Crypto;
  return CommandId.make(`mcp:${yield* crypto.randomUUIDv4().pipe(Effect.orDie)}`);
});
