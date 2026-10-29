import { resolveGitExecutable } from "@t3tools/shared/shell";
import { ThreadId, WorktreeMcpFailure, type WorktreeMcpCommitInput } from "@t3tools/contracts";
import * as HostProcess from "@t3tools/shared/HostProcess";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import * as Stream from "effect/Stream";
import { ChildProcess, ChildProcessSpawner } from "effect/process";
import * as ServerConfig from "../config.ts";

const Authority = Schema.Struct({
  worktreePath: Schema.String,
  adminDir: Schema.String,
  commonDir: Schema.String,
  branch: Schema.String,
});
const AuthorityJson = Schema.fromJsonString(Authority);
const decodeAuthority = Schema.decodeUnknownEffect(AuthorityJson);
const encodeAuthority = Schema.encodeEffect(AuthorityJson);
const isWorktreeMcpFailure = Schema.is(WorktreeMcpFailure);
const refuse = (message: string) => new WorktreeMcpFailure({ code: "invalid_request", message });

export class DelegateWorktreeCommit extends Context.Service<
  DelegateWorktreeCommit,
  {
    readonly branchFor: (threadId: ThreadId) => Effect.Effect<string, WorktreeMcpFailure>;
    readonly record: (
      threadId: ThreadId,
      worktreePath: string,
      branch: string,
    ) => Effect.Effect<void, WorktreeMcpFailure>;
    readonly forget: (threadId: ThreadId) => Effect.Effect<void, WorktreeMcpFailure>;
    readonly available: (threadId: ThreadId) => Effect.Effect<boolean>;
    readonly commit: (
      threadId: ThreadId,
      input: WorktreeMcpCommitInput,
    ) => Effect.Effect<{ commitSha: string }, WorktreeMcpFailure>;
  }
>()("t3/git/DelegateWorktreeCommit") {}

const make = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const crypto = yield* Crypto.Crypto;
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const config = yield* ServerConfig.ServerConfig;
  const environment = yield* HostProcess.Environment;
  const gitExecutable = yield* resolveGitExecutable;
  const directory = path.join(config.stateDir, "delegate-worktree-commits");
  // Serializes index writes through this service; ref updates also compare the old SHA.
  const lock = yield* Semaphore.make(1);
  const key = (threadId: ThreadId) =>
    crypto.digest("SHA-256", new TextEncoder().encode(threadId)).pipe(
      Effect.map((bytes) => Buffer.from(bytes).toString("hex")),
      Effect.mapError(() => refuse("Unable to derive the child worktree identity.")),
    );
  const branchFor = (threadId: ThreadId) => key(threadId).pipe(Effect.map((id) => `t3/${id}/work`));
  const recordPath = (threadId: ThreadId) =>
    key(threadId).pipe(Effect.map((id) => path.join(directory, `${id}.json`)));
  const read = (threadId: ThreadId) =>
    Effect.gen(function* () {
      const file = yield* recordPath(threadId);
      if (!(yield* fs.exists(file))) return Option.none<typeof Authority.Type>();
      return Option.some(yield* decodeAuthority(yield* fs.readFileString(file)));
    });
  const validate = (record: typeof Authority.Type) =>
    Effect.gen(function* () {
      const pointer = (yield* fs.readFileString(path.join(record.worktreePath, ".git"))).trim();
      if (
        !pointer.startsWith("gitdir: ") ||
        (yield* fs.realPath(path.resolve(record.worktreePath, pointer.slice(8)))) !==
          record.adminDir
      )
        return yield* refuse("Refused: the worktree .git pointer changed.");
      const backlink = (yield* fs.readFileString(path.join(record.adminDir, "gitdir"))).trim();
      if (
        (yield* fs.realPath(backlink)) !==
        (yield* fs.realPath(path.join(record.worktreePath, ".git")))
      )
        return yield* refuse("Refused: the admin gitdir backlink changed.");
      const common = (yield* fs.readFileString(path.join(record.adminDir, "commondir"))).trim();
      if ((yield* fs.realPath(path.resolve(record.adminDir, common))) !== record.commonDir)
        return yield* refuse("Refused: the worktree commondir changed.");
      if (
        (yield* fs.readFileString(path.join(record.adminDir, "HEAD"))).trim() !==
        `ref: refs/heads/${record.branch}`
      )
        return yield* refuse("Refused: HEAD is not the recorded child branch.");
    });
  const record = (threadId: ThreadId, worktreePath: string, branch: string) =>
    Effect.gen(function* () {
      if (branch !== (yield* branchFor(threadId)))
        return yield* refuse("Refused: branch is outside the child namespace.");
      const root = yield* fs.realPath(worktreePath);
      const pointer = (yield* fs.readFileString(path.join(root, ".git"))).trim();
      if (!pointer.startsWith("gitdir: ")) return yield* refuse("Refused: not a linked worktree.");
      const adminDir = yield* fs.realPath(path.resolve(root, pointer.slice(8)));
      const commonDir = yield* fs.realPath(
        path.resolve(adminDir, (yield* fs.readFileString(path.join(adminDir, "commondir"))).trim()),
      );
      if (path.dirname(adminDir) !== path.join(commonDir, "worktrees"))
        return yield* refuse("Refused: unexpected worktree admin directory.");
      const authority = { worktreePath: root, adminDir, commonDir, branch };
      yield* validate(authority);
      yield* fs.makeDirectory(directory, { recursive: true });
      // The record is outside the child's checkout and is never refreshed from child-controlled files.
      yield* fs.writeFileString(yield* recordPath(threadId), yield* encodeAuthority(authority), {
        flag: "wx",
      });
    }).pipe(
      Effect.mapError((cause) =>
        isWorktreeMcpFailure(cause) ? cause : refuse("Unable to record child worktree authority."),
      ),
    );
  const commit = (threadId: ThreadId, input: WorktreeMcpCommitInput) =>
    lock.withPermits(1)(
      Effect.gen(function* () {
        if (gitExecutable === undefined)
          return yield* refuse("Refused: Git was not found in absolute PATH entries.");
        const found = yield* read(threadId);
        if (Option.isNone(found))
          return yield* refuse("Refused: this thread has no delegated worktree commit authority.");
        const authority = found.value;
        if (authority.branch !== (yield* branchFor(threadId)))
          return yield* refuse("Refused: invalid child namespace.");
        if (!input.message.trim()) return yield* refuse("Refused: a commit message is required.");
        if (
          input.paths !== undefined &&
          (input.paths.length === 0 ||
            input.paths.some(
              (p) =>
                !p || path.isAbsolute(p) || p.split(/[\\/]/).includes("..") || p.includes("\0"),
            ))
        )
          return yield* refuse("Refused: paths must stay inside the child worktree.");
        yield* validate(authority);
        const hooks = yield* fs.makeTempDirectoryScoped({ directory, prefix: "hooks-" });
        const env = Object.fromEntries(
          Object.entries(environment).filter(([k]) => !k.toUpperCase().startsWith("GIT_")),
        );
        const filterArgs: string[] = [];
        const git = (args: ReadonlyArray<string>, stdin?: string) =>
          Effect.gen(function* () {
            const handle = yield* spawner.spawn(
              ChildProcess.make(
                gitExecutable,
                [
                  "--literal-pathspecs",
                  "-c",
                  `core.hooksPath=${hooks}`,
                  "-c",
                  "core.fsmonitor=false",
                  "-c",
                  "core.untrackedCache=false",
                  "-c",
                  "commit.gpgsign=false",
                  "-c",
                  "gc.auto=0",
                  ...filterArgs,
                  ...args,
                ],
                {
                  cwd: authority.worktreePath,
                  env: {
                    ...env,
                    GIT_DIR: authority.adminDir,
                    GIT_COMMON_DIR: authority.commonDir,
                    GIT_WORK_TREE: authority.worktreePath,
                    GIT_INDEX_FILE: path.join(authority.adminDir, "index"),
                    GIT_TERMINAL_PROMPT: "0",
                  },
                  ...(stdin === undefined
                    ? {}
                    : { stdin: Stream.make(new TextEncoder().encode(stdin)) }),
                },
              ),
            );
            const [stdout, , exitCode] = yield* Effect.all(
              [
                Stream.mkString(Stream.decodeText(handle.stdout)),
                Stream.runDrain(handle.stderr),
                handle.exitCode,
              ],
              { concurrency: "unbounded" },
            );
            if (exitCode !== 0)
              return yield* refuse(`Commit refused: Git ${args[0]} failed (exit ${exitCode}).`);
            return args.includes("-z") ? stdout : stdout.trim();
          });
        const ref = `refs/heads/${authority.branch}`;
        if ((yield* git(["rev-parse", "--symbolic-full-name", ref])) !== ref)
          return yield* refuse("Refused: the recorded child branch redirects to another ref.");
        const parent = yield* git(["rev-parse", "--verify", ref]);
        const filterKeys = (yield* git(["config", "-z", "--name-only", "--list"])).split("\0");
        const configured = new Set(
          filterKeys.flatMap((name) => {
            const match = /^filter\.([\s\S]*)\.(clean|process|required)$/.exec(name);
            return match ? [match[1]!] : [];
          }),
        );
        filterArgs.push(
          ...filterKeys.flatMap((name) =>
            /^filter\.[\s\S]*\.(clean|process|required)$/.test(name)
              ? ["-c", `${name}=${name.endsWith(".required") ? "false" : ""}`]
              : [],
          ),
        );
        // ls-files includes tracked, staged and untracked paths without running clean filters.
        const candidates = yield* git([
          "ls-files",
          "-z",
          "--cached",
          "--others",
          "--exclude-standard",
          "--",
          ...(input.paths ?? ["."]),
        ]);
        const attributes = yield* git(["check-attr", "-z", "--stdin", "filter"], candidates);
        const values = attributes.split("\0");
        for (let i = 2; i < values.length; i += 3) {
          if (configured.has(values[i]!))
            return yield* refuse(
              "Refused: selected paths use a configured Git filter; commit them outside this tool to preserve filtered content (for example Git LFS).",
            );
        }
        // Reject previously staged filtered files too: write-tree may refresh their content.
        const staged = yield* git([
          "diff",
          "--cached",
          "--name-only",
          "-z",
          "--no-ext-diff",
          "--no-textconv",
        ]);
        const stagedAttributes = (yield* git(
          ["check-attr", "-z", "--stdin", "filter"],
          staged,
        )).split("\0");
        for (let i = 2; i < stagedAttributes.length; i += 3) {
          if (configured.has(stagedAttributes[i]!))
            return yield* refuse(
              "Refused: staged paths use a configured Git filter; commit them outside this tool to preserve filtered content (for example Git LFS).",
            );
        }
        yield* git(["add", "--all", "--", ...(input.paths ?? ["."])]);
        const tree = yield* git(["write-tree"]);
        if (tree === (yield* git(["rev-parse", `${parent}^{tree}`])))
          return yield* refuse("Refused: there are no staged changes to commit.");
        const commitSha = yield* git(
          ["commit-tree", tree, "-p", parent, "-F", "-"],
          `${input.message.trimEnd()}\n\nT3-Delegate-Thread: ${threadId}\n`,
        );
        yield* validate(authority);
        // Never update HEAD implicitly: even a concurrent checkout cannot move another branch.
        yield* git([
          "update-ref",
          "--no-deref",
          "-m",
          "t3 worktree commit",
          ref,
          commitSha,
          parent,
        ]);
        return { commitSha };
      }).pipe(
        Effect.scoped,
        Effect.mapError((cause) =>
          isWorktreeMcpFailure(cause)
            ? cause
            : refuse("Commit refused: Git or worktree metadata validation failed."),
        ),
      ),
    );
  return DelegateWorktreeCommit.of({
    branchFor,
    record,
    commit,
    forget: (threadId) =>
      lock.withPermits(1)(
        recordPath(threadId).pipe(
          Effect.flatMap((file) => fs.remove(file, { force: true })),
          Effect.mapError(() => refuse("Unable to remove child worktree authority.")),
        ),
      ),
    available: (threadId) =>
      read(threadId).pipe(
        Effect.map(Option.isSome),
        Effect.orElseSucceed(() => false),
      ),
  });
});
export const layer = Layer.effect(DelegateWorktreeCommit, make);
