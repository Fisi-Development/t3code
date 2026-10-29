import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as HostProcess from "./HostProcess.ts";
import { resolveGitExecutable, SpawnExecutableResolution } from "./shell.ts";

it.effect.each([
  {
    platform: "linux",
    path: ":.:relative:/usr/bin:/opt/git/bin",
    safe: "/usr/bin:/opt/git/bin",
    found: "/usr/bin/git",
  },
  {
    platform: "win32",
    path: ';.;relative;C:relative;\\rooted;"C:\\Program Files\\Git\\cmd";D:\\bin',
    safe: "C:\\Program Files\\Git\\cmd;D:\\bin",
    found: "C:\\Program Files\\Git\\cmd\\git.exe",
  },
] as const)("uses only absolute PATH entries on $platform", ({ platform, path, safe, found }) =>
  Effect.gen(function* () {
    let seen = "";
    const resolved = yield* resolveGitExecutable.pipe(
      Effect.provideService(HostProcess.Platform, platform),
      Effect.provideService(HostProcess.Environment, { PATH: path }),
      Effect.provideService(SpawnExecutableResolution, (_command, _platform, env) => {
        seen = env.PATH!;
        return found;
      }),
    );
    assert.equal(seen, safe);
    assert.equal(resolved, found);
    assert.isUndefined(
      yield* resolveGitExecutable.pipe(
        Effect.provideService(SpawnExecutableResolution, () => "relative/git"),
      ),
    );
  }),
);
