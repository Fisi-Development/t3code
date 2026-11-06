# Delegated completion model

`DelegatedCompletion.tla` models one parent waiting on one delegated task: the child's result, a child that runs again after it, a delivery run cancelled before or after the provider answered it, a linked follower that fails, dies or runs out of retries, a linked child that replies again after its result, and an active Codex goal.

Each `DelegatedCompletion.before-*.cfg` reproduces one failure the tests below cover and must report a violation. `before-cut-before-start` is the exception: a delivery cut before its run started is re-sent and seen once, which is correct. The `after-*` configurations must check clean.

Model check (needs Java and `tla2tools.jar`; set `TLA2TOOLS` to its path):

```sh
apps/server/src/orchestration-v2/model/check.sh
```

The tests for the same cases, from the repository root:

```sh
vp test run apps/server/src/peer/RemoteDelegation.test.ts apps/server/src/orchestration-v2/DelegatedCompletionDelivery.test.ts apps/server/src/orchestration-v2/DelegatedWorkAwaits.test.ts apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.test.ts apps/server/src/orchestration-v2/ThreadManagementService.test.ts
```
