// Wake reliability suite: vp test run apps/server/src/orchestration-v2/pullRequestWatch.wake.test.ts packages/source-control-github/src/server/gitHubChecks.wake.test.ts
import {
  type PullRequestCheck,
  PullRequestComment,
  ThreadPullRequestWatch,
} from "@t3tools/contracts";
import { assert, it } from "@effect/vitest";
import * as Schema from "effect/Schema";

import {
  evaluatePullRequestWatch as evaluate,
  isProgressAcknowledgement,
} from "./pullRequestWatch.ts";

const evaluatePullRequestWatch = (
  ...args: Parameters<typeof evaluate> extends [...infer Head, number] ? Head : never
) => evaluate(...args, 0);

const decodeWatch = Schema.decodeUnknownSync(ThreadPullRequestWatch);
const encodeWatch = Schema.encodeSync(ThreadPullRequestWatch);

const STARTED = "2026-10-02T12:00:00.000Z";

const watch = (overrides: Partial<ThreadPullRequestWatch> = {}): ThreadPullRequestWatch => ({
  startedAt: STARTED,
  headSha: null,
  failedChecks: [],
  passed: false,
  passedChecks: [],
  remarksThrough: STARTED,
  remarkIds: [],
  conflicting: false,
  wakes: 0,
  ...overrides,
});

const check = (name: string, status: PullRequestCheck["status"]): PullRequestCheck => ({
  name,
  status,
  description: null,
  url: `https://ci.example/${name}`,
});

type Detail = Parameters<typeof evaluatePullRequestWatch>[1];

const capabilities = (checksAlwaysReport: boolean): Detail["capabilities"] => ({
  diff: true,
  comment: true,
  actions: [],
  mergeMethods: [],
  search: false,
  review: { inlineComment: false, reply: false, resolve: false, verdicts: [] },
  reviewers: { request: false, listCandidates: false },
  checksAlwaysReport,
});

const detail = (overrides: Partial<Detail> = {}): Detail => ({
  capabilities: capabilities(true),
  headSha: "aaaaaaaaaa",
  checks: [check("lint", "success"), check("test", "pending")],
  mergeability: "mergeable",
  viewer: "agent-user",
  author: { login: "agent-user", name: null, avatarUrl: null },
  ...overrides,
});

const remark = (
  login: string,
  createdAt: string,
  body = "Please rename this.",
): PullRequestComment => ({
  id: `${login}-${createdAt}`,
  kind: "review-comment",
  author: { login, name: null, avatarUrl: null },
  body,
  createdAt,
  url: `https://github.com/o/r/pull/1#${login}`,
  path: "src/index.ts",
  reviewState: null,
});

const noRemarks: ReadonlyArray<PullRequestComment> = [];

const bot = "coderabbitai[bot]";
const stamp = (second: number) => `2026-10-02T12:00:${String(second).padStart(2, "0")}.000Z`;
const walkthrough = (second: number, minutes = 57): PullRequestComment => ({
  ...remark(
    bot,
    "2026-10-02T11:59:00.000Z",
    `<!-- coderabbit-ai-generated:v1 -->
## Walkthrough
Or wait ${minutes} minutes for your next included review.
Run ID: ${second}`,
  ),
  editedAt: stamp(second),
});
const ack = (second: number): PullRequestComment =>
  remark(
    bot,
    stamp(second),
    `<!-- coderabbit-ai-generated:v1 -->
<!-- This is an auto-generated reply by CodeRabbit -->
<!-- CodeRabbit review command invocation: v2:ea0f -->
<details>
<summary>Action performed</summary>

Review triggered.

> Note: CodeRabbit is an incremental review system and does not re-review already reviewed commits. This command is applicable only when automatic reviews are paused.

</details>`,
  );
const remarksChange = (r: PullRequestComment) => [{ kind: "remarks" as const, remarks: [r] }];
const failedChange = (c: PullRequestCheck) => [{ kind: "checks-failed" as const, failed: [c] }];

it("a bot rewriting its own summary again on the same head is not news", () => {
  let state = watch({ headSha: "aaaaaaaaaa" });
  for (const [second, headSha, news] of [
    [1, "aaaaaaaaaa", true],
    [2, "aaaaaaaaaa", false],
    [3, "aaaaaaaaaa", false],
    [4, "bbbbbbbbbb", true],
    [5, "bbbbbbbbbb", false],
  ] as const) {
    const r = walkthrough(second, second === 1 ? 57 : 52);
    const report = evaluatePullRequestWatch(state, detail({ headSha }), [r]);
    assert.deepEqual(report.changes, news ? remarksChange(r) : []);
    state = report.next;
  }
});

it("a note rewritten across four reads of one head wakes once", () => {
  let state = watch({ headSha: "aaaaaaaaaa" });
  const changes = [];
  for (const second of [1, 2, 3, 4]) {
    const report = evaluatePullRequestWatch(state, detail(), [walkthrough(second)]);
    changes.push(...report.changes);
    state = report.next;
  }
  assert.deepEqual(changes, remarksChange(walkthrough(1)));
});

it("each rewritten note wakes once per head", () => {
  let state = watch({ headSha: "aaaaaaaaaa" });
  const changes = [];
  for (const second of [1, 2, 3, 4, 5, 6, 7, 8, 9]) {
    const r = { ...walkthrough(second), id: second % 2 === 1 ? "one" : "two" };
    const report = evaluatePullRequestWatch(state, detail(), [r]);
    changes.push(...report.changes);
    state = report.next;
  }
  assert.deepEqual(changes, [
    ...remarksChange({ ...walkthrough(1), id: "one" }),
    ...remarksChange({ ...walkthrough(2), id: "two" }),
  ]);
});

it("CodeRabbit's review triggered reply is not news", () => {
  const triggered = ack(1);
  const first = evaluatePullRequestWatch(watch(), detail(), [triggered]);
  assert.deepEqual(first.changes, []);
  assert.equal(first.next.remarksThrough, triggered.createdAt);
  const finished = {
    ...triggered,
    editedAt: stamp(2),
    body: triggered.body.replace("Review triggered.", "Review finished."),
  };
  const second = evaluatePullRequestWatch(first.next, detail(), [finished]);
  assert.deepEqual(second.changes, remarksChange(finished));
  const answer = remark(
    bot,
    stamp(3),
    "<!-- This is an auto-generated reply by CodeRabbit --> The retry uses the latest head.",
  );
  const third = evaluatePullRequestWatch(second.next, detail(), [answer]);
  assert.deepEqual(third.changes, remarksChange(answer));
  const limited = {
    ...ack(4),
    body: ack(4)
      .body.replace("Action performed", "Action not completed")
      .replace("Review triggered.", "Review rate limited."),
  };
  assert.deepEqual(
    evaluatePullRequestWatch(third.next, detail(), [limited]).changes,
    remarksChange(limited),
  );
  assert.isTrue(
    isProgressAcknowledgement({
      ...ack(5),
      body: `<!-- This is an auto-generated reply by CodeRabbit -->
<details>
<summary>✅ Actions performed</summary>

Full review triggered.

</details>`,
    }),
  );
});

it("the acknowledgement's outcome edit wakes once", () => {
  const triggered = ack(1);
  const first = evaluatePullRequestWatch(watch(), detail(), [triggered]);
  assert.deepEqual(first.changes, []);
  const finished = {
    ...triggered,
    editedAt: stamp(2),
    body: triggered.body.replace("Review triggered.", "Review finished."),
  };
  const second = evaluatePullRequestWatch(first.next, detail(), [finished]);
  assert.deepEqual(second.changes, remarksChange(finished));
  assert.deepEqual(
    evaluatePullRequestWatch(second.next, detail(), [{ ...finished, editedAt: stamp(3) }]).changes,
    [],
  );
});

it("checks passing again after a pending read is not news", () => {
  let state = watch();
  for (const [status, expected] of [
    ["success", [{ kind: "checks-passed", count: 1, required: false }]],
    ["pending", []],
    ["success", []],
    ["failure", failedChange(check("Pipeline", "failure"))],
    ["success", [{ kind: "checks-passed", count: 1, required: false }]],
  ] as const) {
    const report = evaluatePullRequestWatch(
      state,
      detail({ checks: [check("Pipeline", status)] }),
      noRemarks,
    );
    assert.deepEqual(report.changes, expected);
    state = report.next;
  }
});

it("a required check rerun on the same head does not repeat the pass", () => {
  let state = watch();
  for (const [status, headSha, news] of [
    ["success", "aaaaaaaaaa", true],
    ["pending", "aaaaaaaaaa", false],
    ["success", "aaaaaaaaaa", false],
    ["success", "bbbbbbbbbb", true],
  ] as const) {
    const report = evaluatePullRequestWatch(
      state,
      detail({ headSha, checks: [{ ...check("test", status), required: true }] }),
      noRemarks,
    );
    assert.deepEqual(
      report.changes,
      news ? [{ kind: "checks-passed", count: 1, required: true }] : [],
    );
    state = report.next;
  }
});

it("a retried job that fails again is news", () => {
  const failed = check("lint", "failure");
  const first = evaluatePullRequestWatch(watch(), detail({ checks: [failed] }), noRemarks);
  assert.deepEqual(first.changes, failedChange(failed));
  const pending = evaluatePullRequestWatch(
    first.next,
    detail({ checks: [check("lint", "pending")] }),
    noRemarks,
  );
  assert.deepEqual(pending.changes, []);
  assert.deepEqual(
    evaluatePullRequestWatch(pending.next, detail({ checks: [failed] }), noRemarks).changes,
    failedChange(failed),
  );
});

it("a new conflict after a resolving push is news", () => {
  const first = evaluatePullRequestWatch(
    watch(),
    detail({ mergeability: "conflicting" }),
    noRemarks,
  );
  assert.deepEqual(first.changes, [{ kind: "conflicting" }]);
  const clean = evaluatePullRequestWatch(first.next, detail({ headSha: "bbbbbbbbbb" }), noRemarks);
  assert.deepEqual(clean.changes, []);
  assert.deepEqual(
    evaluatePullRequestWatch(
      clean.next,
      detail({ headSha: "bbbbbbbbbb", mergeability: "conflicting" }),
      noRemarks,
    ).changes,
    [{ kind: "conflicting" }],
  );
});

it("a rerun that fails again between two reads is news", () => {
  const u1 = { ...check("lint", "failure"), url: "https://ci.example/jobs/1" };
  const u2 = { ...u1, url: "https://ci.example/jobs/2" };
  const first = evaluatePullRequestWatch(watch(), detail({ checks: [u1] }), noRemarks);
  assert.deepEqual(first.changes, failedChange(u1));
  const second = evaluatePullRequestWatch(first.next, detail({ checks: [u2] }), noRemarks);
  assert.deepEqual(second.changes, failedChange(u2));
  assert.deepEqual(
    evaluatePullRequestWatch(second.next, detail({ checks: [u2] }), noRemarks).changes,
    [],
  );
  assert.deepEqual(
    evaluatePullRequestWatch(
      watch({ headSha: "aaaaaaaaaa", failedChecks: ["lint"] }),
      detail({ checks: [u2] }),
      noRemarks,
    ).changes,
    [],
  );
});

it("watching again does not repeat an edit from before the watch", () => {
  const old = { ...walkthrough(1), editedAt: "2026-10-02T11:59:59.000Z" };
  assert.deepEqual(evaluatePullRequestWatch(watch(), detail(), [old]).changes, []);
});

it("a CI status comment rewritten on a new head wakes once", () => {
  const old = evaluatePullRequestWatch(watch(), detail(), noRemarks);
  const r = {
    ...walkthrough(1),
    author: { login: "blacksmith[bot]", name: null, avatarUrl: null },
    body: "CI running on head B",
  };
  const first = evaluatePullRequestWatch(old.next, detail({ headSha: "bbbbbbbbbb" }), [r]);
  assert.deepEqual(first.changes, remarksChange(r));
  assert.deepEqual(
    evaluatePullRequestWatch(first.next, detail({ headSha: "bbbbbbbbbb" }), [
      { ...r, editedAt: stamp(2), body: "CI complete on head B" },
    ]).changes,
    [],
  );
});

it("a restart keeps what the watch already told", () => {
  const roundTrip = (state: ThreadPullRequestWatch) => {
    const encoded: unknown = JSON.parse(JSON.stringify(encodeWatch(state)));
    return decodeWatch(encoded);
  };
  const u1 = { ...check("lint", "failure"), url: "https://ci.example/jobs/1" };
  const u2 = { ...u1, url: "https://ci.example/jobs/2" };
  const first = evaluatePullRequestWatch(watch(), detail({ checks: [u1] }), [walkthrough(1)]);
  assert.deepEqual(first.changes, [...failedChange(u1), ...remarksChange(walkthrough(1))]);
  const second = evaluatePullRequestWatch(roundTrip(first.next), detail({ checks: [u2] }), [
    walkthrough(2, 52),
  ]);
  assert.deepEqual(second.changes, failedChange(u2));
  const third = evaluatePullRequestWatch(roundTrip(second.next), detail({ checks: [u2] }), [
    walkthrough(3, 52),
  ]);
  assert.deepEqual(third.changes, []);
  const pushed = evaluatePullRequestWatch(
    roundTrip(third.next),
    detail({ headSha: "bbbbbbbbbb" }),
    [walkthrough(4, 52)],
  );
  assert.deepEqual(pushed.changes, remarksChange(walkthrough(4, 52)));
  assert.deepEqual(
    evaluatePullRequestWatch(roundTrip(pushed.next), detail({ headSha: "bbbbbbbbbb" }), [
      walkthrough(5, 52),
    ]).changes,
    [],
  );
  const legacyEncoded: unknown = JSON.parse(JSON.stringify(watch({ headSha: "aaaaaaaaaa" })));
  const legacy = decodeWatch(legacyEncoded);
  assert.deepEqual(evaluatePullRequestWatch(legacy, detail(), noRemarks).changes, []);
});
