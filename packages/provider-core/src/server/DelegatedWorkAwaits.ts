import type { ThreadId } from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";

/** True while the thread has delegated tasks whose completion will wake it. */
export class DelegatedWorkAwaits extends Context.Reference<{
  readonly awaitsDelegatedWork: (
    threadId: ThreadId,
    options: { readonly includeClaimedDeliveries: boolean },
  ) => Effect.Effect<boolean>;
}>("@t3tools/provider-core/server/DelegatedWorkAwaits", {
  defaultValue: () => ({ awaitsDelegatedWork: () => Effect.succeed(false) }),
}) {}
