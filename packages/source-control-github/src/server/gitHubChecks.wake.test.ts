// Wake reliability suite: vp test run apps/server/src/orchestration-v2/pullRequestWatch.wake.test.ts packages/source-control-github/src/server/gitHubChecks.wake.test.ts
import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import { toPullRequestCore } from "./gitHubPullRequestJson.ts";
import { PullRequestCore } from "./pullRequestReads.graphql.ts";

const run = (
  event: string,
  conclusion: string | null,
  fields: Record<string, unknown> = {},
): Record<string, unknown> => ({
  __typename: "CheckRun",
  name: "check",
  status: conclusion === null ? "IN_PROGRESS" : "COMPLETED",
  conclusion,
  startedAt: "2026-10-08T04:06:10Z",
  completedAt: conclusion === null ? null : "2026-10-08T04:18:58Z",
  detailsUrl: null,
  checkSuite: { workflowRun: { event, workflow: { name: "Checks" } } },
  ...fields,
});

const coreJson = (
  rollup: ReadonlyArray<Record<string, unknown>>,
  pullRequest: Record<string, unknown> = {},
) =>
  JSON.stringify({
    data: {
      repository: {
        mergeCommitAllowed: true,
        squashMergeAllowed: true,
        rebaseMergeAllowed: true,
        autoMergeAllowed: true,
        viewerPermission: "WRITE",
        pullRequest: {
          number: 7,
          title: "Detail",
          url: "https://github.com/pingdotgg/t3code/pull/7",
          body: "Body",
          state: "OPEN",
          isDraft: false,
          mergeable: "MERGEABLE",
          mergeStateStatus: "BLOCKED",
          reviewDecision: null,
          additions: 0,
          deletions: 0,
          changedFiles: 0,
          createdAt: "2026-07-01T00:00:00Z",
          updatedAt: "2026-07-05T00:00:00Z",
          mergedAt: null,
          closedAt: null,
          headRefName: "feat/detail",
          baseRefName: "main",
          headRefOid: "abc123",
          isCrossRepository: false,
          maintainerCanModify: true,
          headRepositoryOwner: null,
          headRepository: null,
          headRef: null,
          author: null,
          autoMergeRequest: null,
          viewerCanUpdate: true,
          viewerDidAuthor: false,
          viewerCanUpdateBranch: false,
          baseRef: null,
          reviewRequests: { nodes: [] },
          labels: { nodes: [] },
          commits: {
            nodes: [
              {
                commit: {
                  statusCheckRollup: {
                    contexts: {
                      nodes: rollup,
                      pageInfo: { hasNextPage: false, endCursor: null },
                    },
                  },
                },
              },
            ],
          },
          ...pullRequest,
        },
      },
    },
  });

const decodeCore = Schema.decodeUnknownSync(PullRequestCore.result);

const detailOf = (rollup: ReadonlyArray<Record<string, unknown>>) => {
  const raw = JSON.parse(coreJson(rollup)) as { data: unknown };
  const result = toPullRequestCore(decodeCore(raw.data));
  if (result === null) throw new Error("Pull request not found");
  return result;
};

const statuses = (rollup: ReadonlyArray<Record<string, unknown>>) =>
  detailOf(rollup).checks.map(({ name, status }) => [name, status]);

describe("GitHub workflow event rollup", () => {
  it("a failed push run is not hidden by a running pull_request run", () => {
    const failed = run("push", "FAILURE");
    const running = run("pull_request", null);
    for (const rollup of [
      [failed, running],
      [running, failed],
    ]) {
      expect(statuses(rollup)).toEqual([["check", "failure"]]);
      expect(detailOf(rollup).checksState).toBe("failing");
    }
  });

  it("a failed run stays failed after the other event's run passes", () => {
    expect(
      statuses([
        run("push", "FAILURE"),
        run("pull_request", "SUCCESS", { completedAt: "2026-10-08T05:00:00Z" }),
      ]),
    ).toEqual([["check", "failure"]]);
  });

  it("runs from both events passing read as passed", () => {
    const passing = [run("push", "SUCCESS"), run("pull_request", "SUCCESS")];
    expect(statuses(passing)).toEqual([["check", "success"]]);
    expect(detailOf(passing).checksState).toBe("passing");
    expect(statuses([run("push", "SUCCESS"), run("pull_request", null)])).toEqual([
      ["check", "pending"],
    ]);
  });

  it("a run cancelled next to a passing run is not a failure", () => {
    expect(statuses([run("push", "CANCELLED"), run("pull_request", "SUCCESS")])).toEqual([
      ["check", "success"],
    ]);
    expect(statuses([run("push", "CANCELLED")])).toEqual([["check", "cancelled"]]);
  });

  it("the same job name in two workflows stays two checks", () => {
    const workflow = (name: string) => ({ workflowRun: { event: "push", workflow: { name } } });
    expect(
      statuses([
        run("push", "FAILURE", { name: "build", checkSuite: workflow("Lint") }),
        run("pull_request", "SUCCESS", {
          name: "build",
          checkSuite: { workflowRun: { event: "pull_request", workflow: { name: "Test" } } },
        }),
      ]),
    ).toEqual([
      ["Lint / build", "failure"],
      ["Test / build", "success"],
    ]);
  });

  it("reruns within one event keep the newest attempt", () => {
    expect(
      statuses([
        run("pull_request", "FAILURE"),
        run("pull_request", "SUCCESS", { completedAt: "2026-10-08T05:00:00Z" }),
      ]),
    ).toEqual([["check", "success"]]);
  });

  it("the required flag survives merging the events", () => {
    expect(
      detailOf([
        run("push", "SUCCESS", { isRequired: true }),
        run("pull_request", null, { isRequired: false }),
      ]).checks,
    ).toMatchObject([{ name: "check", status: "pending", required: true }]);
  });
});
