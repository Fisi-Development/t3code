// @effect-diagnostics nodeBuiltinImport:off - lstat and exclusive copy are not exposed by Effect FileSystem.
import * as NodeFSP from "node:fs/promises";
import * as Effect from "effect/Effect";
import * as Path from "effect/Path";

export const copyIncludedWorktreeFiles = Effect.fn("copyIncludedWorktreeFiles")(function* (
  sourceRoot: string,
  destinationRoot: string,
  relativePaths: ReadonlyArray<string>,
) {
  const path = yield* Path.Path;
  for (const relativePath of relativePaths) {
    yield* Effect.tryPromise(async () => {
      const source = path.join(sourceRoot, relativePath);
      const destination = path.join(destinationRoot, relativePath);
      if (!(await NodeFSP.lstat(source)).isFile()) return;
      await NodeFSP.mkdir(path.dirname(destination), { recursive: true });
      try {
        await NodeFSP.copyFile(source, destination, NodeFSP.constants.COPYFILE_EXCL);
      } catch (cause) {
        if (
          typeof cause === "object" &&
          cause !== null &&
          "code" in cause &&
          cause.code === "EEXIST"
        )
          return;
        throw cause;
      }
    }).pipe(Effect.catch(() => Effect.logWarning("worktree include file copy failed")));
  }
});
