import { assert, describe, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { ThreadId } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Stream from "effect/Stream";
import { ChildProcess, ChildProcessSpawner } from "effect/process";
import * as ServerConfig from "../config.ts";
import * as Commits from "./DelegateWorktreeCommit.ts";

const fixture = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const service = yield* Commits.DelegateWorktreeCommit;
  const root = yield* fs.realPath(yield* fs.makeTempDirectoryScoped({ prefix: "t3-commit-test-" }));
  const repo = path.join(root, "repo");
  const child = path.join(root, "child with spaces");
  const threadId = ThreadId.make(root);
  const branch = yield* service.branchFor(threadId);
  const git = (cwd: string, ...args: string[]) =>
    Effect.gen(function* () {
      const process = yield* spawner.spawn(ChildProcess.make("git", ["-C", cwd, ...args]));
      const [stdout, , code] = yield* Effect.all(
        [
          Stream.mkString(Stream.decodeText(process.stdout)),
          Stream.runDrain(process.stderr),
          process.exitCode,
        ],
        { concurrency: "unbounded" },
      );
      assert.equal(code, 0, `git ${args[0]} failed`);
      return stdout.trim();
    });
  yield* fs.makeDirectory(repo);
  yield* git(repo, "init", "-b", "main");
  yield* git(repo, "config", "user.name", "Commit test");
  yield* git(repo, "config", "user.email", "commit@example.com");
  yield* git(repo, "commit", "--allow-empty", "-m", "initial");
  yield* git(repo, "worktree", "add", "-b", branch, child);
  yield* service.record(threadId, child, branch);
  const admin = yield* git(child, "rev-parse", "--absolute-git-dir");
  yield* fs.writeFileString(path.join(child, "change.txt"), "child work\n");
  return { fs, path, root, repo, child, admin, threadId, branch, git, service };
});
const layer = Commits.layer.pipe(
  Layer.provideMerge(ServerConfig.layerTest(process.cwd(), { prefix: "t3-commit-state-" })),
  Layer.provideMerge(NodeServices.layer),
);

describe("delegate worktree commit", () => {
  it.effect(
    "commits all changes only on the recorded child branch and survives service recreation",
    () =>
      Effect.gen(function* () {
        const f = yield* fixture;
        assert.match(f.branch, /^t3\/[a-f0-9]{64}\/work$/);
        const main = yield* f.git(f.repo, "rev-parse", "main");
        const result = yield* f.service.commit(f.threadId, { message: "child commit" });
        assert.equal(yield* f.git(f.child, "rev-parse", "HEAD"), result.commitSha);
        assert.equal(yield* f.git(f.child, "show", "HEAD:change.txt"), "child work");
        assert.equal(yield* f.git(f.repo, "rev-parse", "main"), main);
        assert.equal(yield* f.git(f.child, "status", "--porcelain"), "");
        const restored = yield* Commits.DelegateWorktreeCommit.pipe(Effect.provide(Commits.layer));
        assert.isTrue(yield* restored.available(f.threadId));
        assert.isFalse(yield* restored.available(ThreadId.make("non-delegate")));
      }).pipe(Effect.scoped, Effect.provide(layer)),
  );
  it.effect("refuses a child branch redirected to main without moving main", () =>
    Effect.gen(function* () {
      const f = yield* fixture;
      const before = yield* f.git(f.repo, "rev-parse", "main");
      yield* f.git(f.child, "symbolic-ref", `refs/heads/${f.branch}`, "refs/heads/main");
      const failure = yield* Effect.flip(f.service.commit(f.threadId, { message: "must refuse" }));
      assert.include(failure.message, "redirects to another ref");
      assert.equal(yield* f.git(f.repo, "rev-parse", "main"), before);
    }).pipe(Effect.scoped, Effect.provide(layer)),
  );
  it.effect("stages only literal selected paths and rejects paths outside the checkout", () =>
    Effect.gen(function* () {
      const f = yield* fixture;
      yield* f.fs.writeFileString(f.path.join(f.child, "other.txt"), "other");
      const outside = yield* Effect.flip(
        f.service.commit(f.threadId, { message: "bad", paths: ["../repo"] }),
      );
      assert.include(outside.message, "paths must stay inside");
      yield* f.service.commit(f.threadId, { message: "selected", paths: ["change.txt"] });
      assert.equal(yield* f.git(f.child, "ls-tree", "--name-only", "HEAD"), "change.txt");
      assert.include(yield* f.git(f.child, "status", "--porcelain"), "other.txt");
    }).pipe(Effect.scoped, Effect.provide(layer)),
  );
  it.effect.each(["HEAD", "commondir", "gitdir", ".git"] as const)(
    "refuses changed %s without moving any branch",
    (field) =>
      Effect.gen(function* () {
        const f = yield* fixture;
        const before = yield* f.git(f.repo, "show-ref");
        const file = field === ".git" ? f.path.join(f.child, ".git") : f.path.join(f.admin, field);
        const replacement =
          field === "HEAD"
            ? "ref: refs/heads/main\n"
            : field === "commondir"
              ? f.repo
              : field === "gitdir"
                ? f.path.join(f.repo, ".git")
                : `gitdir: ${f.path.join(f.repo, ".git")}`;
        const previous = yield* f.fs.readFileString(file);
        yield* f.fs.writeFileString(file, replacement);
        const failure = yield* Effect.flip(
          f.service.commit(f.threadId, { message: "must refuse" }),
        );
        assert.include(failure.message, field === "HEAD" ? "HEAD" : field);
        yield* f.fs.writeFileString(file, previous);
        assert.equal(yield* f.git(f.repo, "show-ref"), before);
      }).pipe(Effect.scoped, Effect.provide(layer)),
  );
  it.effect("does not run configured hooks, fsmonitor, clean filters, or signing commands", () =>
    Effect.gen(function* () {
      const f = yield* fixture;
      const callback = f.path.join(f.root, "callback");
      const marker = f.path.join(f.root, "callback-ran");
      yield* f.fs.writeFileString(
        callback,
        `#!/bin/sh\nprintf called > '${marker.replaceAll("'", "'\\''")}'\nexit 1\n`,
      );
      yield* f.fs.chmod(callback, 0o755);
      const hooks = f.path.join(f.root, "configured-hooks");
      yield* f.fs.makeDirectory(hooks);
      for (const hook of ["pre-commit", "commit-msg", "post-commit", "reference-transaction"]) {
        yield* f.fs.copyFile(callback, f.path.join(hooks, hook));
        yield* f.fs.chmod(f.path.join(hooks, hook), 0o755);
      }
      yield* f.git(f.repo, "config", "core.hooksPath", hooks);
      yield* f.git(f.repo, "config", "core.fsmonitor", callback);
      yield* f.git(f.repo, "config", "filter.test.clean", callback);
      yield* f.git(f.repo, "config", "filter.test.required", "true");
      yield* f.git(f.repo, "config", "commit.gpgsign", "true");
      yield* f.git(f.repo, "config", "gpg.program", callback);
      yield* f.fs.writeFileString(f.path.join(f.child, ".gitattributes"), "*.txt filter=test\n");
      const { commitSha } = yield* f.service.commit(f.threadId, { message: "safe commit" });
      assert.match(commitSha, /^[a-f0-9]{40,64}$/);
      assert.isFalse(yield* f.fs.exists(marker));
    }).pipe(Effect.scoped, Effect.provide(layer)),
  );
});
