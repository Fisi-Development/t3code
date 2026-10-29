import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";
import { ChildProcess, ChildProcessSpawner } from "effect/process";
import { codexWorktreeWritableRoots } from "./CodexWorktreeSandbox.ts";

describe("Codex worktree sandbox roots", () => {
  it.effect("resolves real linked worktrees without granting sibling metadata or config", () =>
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
      const git = (cwd: string, ...args: string[]) =>
        spawner
          .string(
            ChildProcess.make("git", [
              "-c",
              "user.name=Test",
              "-c",
              "user.email=test@example.com",
              "-C",
              cwd,
              ...args,
            ]),
          )
          .pipe(Effect.map((s) => s.trim()));
      const root = yield* fs.realPath(
        yield* fs.makeTempDirectoryScoped({ prefix: "codex-git-roots-" }),
      );
      const repo = path.join(root, "repo");
      const child = path.join(root, "child with spaces");
      const sibling = path.join(root, "sibling");
      yield* fs.makeDirectory(repo);
      yield* git(repo, "init");
      yield* git(repo, "commit", "--allow-empty", "-m", "initial");
      yield* git(repo, "worktree", "add", "-b", "child", child);
      yield* git(repo, "worktree", "add", "-b", "sibling", sibling);
      const roots = yield* codexWorktreeWritableRoots(child);
      const gitDir = yield* git(child, "rev-parse", "--absolute-git-dir");
      const common = path.join(repo, ".git");
      const covers = (target: string) =>
        roots.some((r) => target === r || target.startsWith(r + path.sep));
      assert.isTrue(covers(path.join(gitDir, "index.lock")));
      assert.isTrue(covers(path.join(common, "objects", "ab", "object")));
      assert.isTrue(covers(path.join(common, "refs", "heads", "child.lock")));
      assert.isTrue(covers(path.join(common, "logs", "refs", "heads", "child")));
      assert.isFalse(
        covers(path.join(yield* git(sibling, "rev-parse", "--absolute-git-dir"), "index.lock")),
      );
      assert.isFalse(covers(path.join(common, "config")));
      assert.isFalse(covers(path.join(common, "hooks", "pre-commit")));
      assert.deepEqual(yield* codexWorktreeWritableRoots(repo), []);
      assert.deepEqual(yield* codexWorktreeWritableRoots(root), []);
      yield* fs.writeFileString(path.join(gitDir, "gitdir"), path.join(sibling, ".git"));
      assert.deepEqual(yield* codexWorktreeWritableRoots(child), []);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );
});
