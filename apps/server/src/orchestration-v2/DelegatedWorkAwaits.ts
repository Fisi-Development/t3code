import * as DelegatedWorkAwaits from "@t3tools/provider-core/server/DelegatedWorkAwaits";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

export const layer = Layer.succeed(DelegatedWorkAwaits.DelegatedWorkAwaits, {
  awaitsDelegatedWork: () => Effect.succeed(false),
});
