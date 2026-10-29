import * as Path from "effect/Path";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";

export const codexWorktreeWritableRoots = Effect.fn("codexWorktreeWritableRoots")(function* (
  worktreePath: string,
) {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  return yield* Effect.gen(function* () {
    const dotGit = path.join(worktreePath, ".git");
    const pointer = (yield* fs.readFileString(dotGit)).trim();
    if (!pointer.startsWith("gitdir: ")) return [];
    const gitDir = yield* fs.realPath(path.resolve(worktreePath, pointer.slice(8)));
    const commonDir = yield* fs.realPath(
      path.resolve(gitDir, (yield* fs.readFileString(path.join(gitDir, "commondir"))).trim()),
    );
    // Grant this linked worktree's admin directory, never the worktrees container
    // or common directory, which would expose sibling indexes and Git config/hooks.
    if (path.dirname(gitDir) !== path.join(commonDir, "worktrees")) return [];
    const backlink = (yield* fs.readFileString(path.join(gitDir, "gitdir"))).trim();
    if ((yield* fs.realPath(backlink)) !== (yield* fs.realPath(dotGit))) return [];
    return [
      gitDir,
      path.join(commonDir, "objects"),
      path.join(commonDir, "refs"),
      path.join(commonDir, "logs", "refs"),
    ];
  }).pipe(Effect.orElseSucceed(() => []));
});
