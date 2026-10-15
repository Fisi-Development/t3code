import { useAtomValue } from "@effect/atom-react";
import { deriveReportedModelSelection } from "@t3tools/client-runtime/state/thread-execution";
import { resolveThreadLink, type ThreadLinkTarget } from "@t3tools/client-runtime/state/threads";

import { appAtomRegistry } from "./atom-registry";
import type {
  EnvironmentProject,
  EnvironmentThread,
  EnvironmentThreadShell,
} from "@t3tools/client-runtime/state/shell";
import type {
  EnvironmentId,
  ScopedProjectRef,
  ScopedThreadRef,
  ServerConfig,
  ThreadId,
} from "@t3tools/contracts";
import { hasThreadLinks, relabelThreadLinks } from "@t3tools/shared/threadLinks";
import { Atom } from "effect/reactivity";
import { useMemo } from "react";

import { environmentProjects } from "./projects";
import { environmentServerConfigsAtom, serverEnvironment } from "./server";
import { environmentThreadDetails, environmentThreadShells } from "./threads";

const EMPTY_PROJECT_ATOM = Atom.make<EnvironmentProject | null>(null).pipe(
  Atom.withLabel("mobile-project:empty"),
);
const EMPTY_THREAD_SHELL_ATOM = Atom.make<EnvironmentThreadShell | null>(null).pipe(
  Atom.withLabel("mobile-thread-shell:empty"),
);
const EMPTY_SERVER_CONFIG_ATOM = Atom.make<ServerConfig | null>(null).pipe(
  Atom.withLabel("mobile-server-config:empty"),
);
const EMPTY_THREAD_ATOM = Atom.make<EnvironmentThread | null>(null).pipe(
  Atom.withLabel("mobile-thread:empty"),
);
const EMPTY_THREAD_LINK_TARGETS_ATOM = Atom.make<ReadonlyMap<ThreadId, ThreadLinkTarget>>(
  new Map(),
).pipe(Atom.withLabel("mobile-thread-link-targets:empty"));

/** Resolves when the project event reaches the live client store. */
export function waitForProject(
  ref: ScopedProjectRef,
  timeoutMs = 10_000,
): Promise<EnvironmentProject | null> {
  const atom = environmentProjects.projectAtom(ref);
  const current = appAtomRegistry.get(atom);
  if (current !== null) return Promise.resolve(current);
  return new Promise((resolve) => {
    let unsubscribe: (() => void) | null = null;
    const timeout = setTimeout(() => {
      unsubscribe?.();
      resolve(null);
    }, timeoutMs);
    const finish = (project: EnvironmentProject | null) => {
      if (project === null) return;
      clearTimeout(timeout);
      unsubscribe?.();
      resolve(project);
    };
    unsubscribe = appAtomRegistry.subscribe(atom, finish);
    finish(appAtomRegistry.get(atom));
  });
}

export function useProjects(): ReadonlyArray<EnvironmentProject> {
  return useAtomValue(environmentProjects.projectsAtom);
}

export function useThreadShells(): ReadonlyArray<EnvironmentThreadShell> {
  return useAtomValue(environmentThreadShells.threadShellsAtom);
}

export function useNavigationThreadShells(): ReadonlyArray<EnvironmentThreadShell> {
  return useAtomValue(environmentThreadShells.navigationThreadShellsAtom);
}

export function useProject(ref: ScopedProjectRef | null): EnvironmentProject | null {
  return useAtomValue(ref === null ? EMPTY_PROJECT_ATOM : environmentProjects.projectAtom(ref));
}

export function useThreadShell(ref: ScopedThreadRef | null): EnvironmentThreadShell | null {
  return useAtomValue(
    ref === null ? EMPTY_THREAD_SHELL_ATOM : environmentThreadShells.threadShellAtom(ref),
  );
}

export function useChildThreadInputs(ref: ScopedThreadRef) {
  return useAtomValue(environmentThreadShells.childThreadInputsAtom(ref));
}

/** `markdown`, from a message in `environmentId`, with each thread link labeled by the
    linked thread's current title in whichever connected environment holds it. */
export function useLiveThreadLinkLabels(markdown: string, environmentId: EnvironmentId): string {
  const targets = useAtomValue(
    hasThreadLinks(markdown)
      ? environmentThreadShells.threadLinkTargetsAtom(environmentId)
      : EMPTY_THREAD_LINK_TARGETS_ATOM,
  );
  return useMemo(
    () =>
      targets.size === 0
        ? markdown
        : relabelThreadLinks(markdown, (threadId) => targets.get(threadId)?.title),
    [markdown, targets],
  );
}

/** The thread a link in a message from `environmentId` opens. A thread no connected
    environment holds opens in `environmentId`, which can still show it if archived. */
export function threadLinkDestination(
  environmentId: EnvironmentId,
  threadId: ThreadId,
): ScopedThreadRef {
  const target = resolveThreadLink(
    appAtomRegistry.get(environmentThreadShells.threadLinkTargetsAtom(environmentId)),
    threadId,
  );
  return target === null
    ? { environmentId, threadId }
    : { environmentId: target.environmentId, threadId: target.threadId };
}

export function useEnvironmentServerConfig(
  environmentId: EnvironmentId | null,
): ServerConfig | null {
  return useAtomValue(
    environmentId === null
      ? EMPTY_SERVER_CONFIG_ATOM
      : serverEnvironment.configValueAtom(environmentId),
  );
}

export function useServerConfigs(): ReadonlyMap<EnvironmentId, ServerConfig> {
  return useAtomValue(environmentServerConfigsAtom);
}

const selectReportedModelSelection = (thread: EnvironmentThread | null) =>
  thread === null ? null : deriveReportedModelSelection(thread.projection);

export function useThreadReportedModelSelection(ref: ScopedThreadRef | null) {
  return useAtomValue(
    ref === null ? EMPTY_THREAD_ATOM : environmentThreadDetails.threadAtom(ref),
    selectReportedModelSelection,
  );
}
