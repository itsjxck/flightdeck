// Goal workers' worktrees and their PRs. The coordinator removes worktrees as
// tasks finish (worktree_remove, store.requestWorktreeRemoval); this module
// serves the user's Close goal: `goalWorktrees` lists what's left with each
// PR's state, and `queueMerged` removes the merged ones when the user confirms.
// The window runs queued removals (`wt remove`, branch too) and reports back.
//
// PRs are found by branch with `gh pr list --head`, cached for PR_TTL_MS, and
// recorded on the task when it hadn't recorded one itself.
import { existsSync } from "node:fs";
import { githubRepo, prForBranch, type PullRequest } from "./github";
import type { Store, Task } from "./store";

const PR_TTL_MS = 2 * 60_000;
const prCache = new Map<string, { at: number; pr: PullRequest | null }>();

export interface GoalWorktree {
  task: string; title: string; status: string; branch: string; worktree: string; repoPath: string | null;
  pr: PullRequest | null; queued: boolean;
}

async function remoteSlug(repoPath: string): Promise<string | null> {
  const p = Bun.spawn(["git", "-C", repoPath, "remote", "get-url", "origin"], { stdout: "pipe", stderr: "ignore" });
  const out = await new Response(p.stdout).text();
  return (await p.exited) === 0 ? githubRepo(out) : null;
}

async function prOf(store: Store, t: Task, repoPath: string | null): Promise<PullRequest | null> {
  if (!t.branch || !repoPath) return null;
  const key = `${repoPath}|${t.branch}`;
  const hit = prCache.get(key);
  // A merged PR stays merged; anything else is looked up again after PR_TTL_MS.
  if (hit && (hit.pr?.state === "MERGED" || Date.now() - hit.at < PR_TTL_MS)) return hit.pr;
  const slug = await remoteSlug(repoPath);
  const pr = slug ? await prForBranch(slug, t.branch) : null;
  prCache.set(key, { at: Date.now(), pr });
  if (pr && !t.pr) store.setTaskPr(t.id, pr.url);
  return pr;
}

// A goal's worker worktrees (not its coordinator's checkout), with each PR's state.
export async function goalWorktrees(store: Store, goal: number): Promise<GoalWorktree[]> {
  const g = store.goal(goal);
  const out: GoalWorktree[] = [];
  for (const t of store.listTasks({ goal })) {
    if (!t.worktree || !t.branch || t.session === g.coordinator) continue;
    const repoPath = store.repoPath(t.repo);
    if (!repoPath || t.worktree === repoPath) continue;
    // Removed outside Flightdeck (by hand, wt merge): forget it.
    if (!existsSync(t.worktree)) { store.cleanupDone(t.id); continue; }
    out.push({ task: store.tref(t.id), title: t.title, status: t.status, branch: t.branch, worktree: t.worktree, repoPath,
      pr: await prOf(store, t, repoPath), queued: store.cleanupQueued(t.id) });
  }
  return out;
}

// Queues the removal of finished tasks' worktrees whose PR merged (the user closing the goal).
// `all`: also those whose worker is still open.
export async function queueMerged(store: Store, goal: number, all = false): Promise<number> {
  let queued = 0;
  for (const w of await goalWorktrees(store, goal)) {
    if (w.queued || w.pr?.state !== "MERGED" || w.status !== "done") continue;
    const id = store.taskId(w.task);
    if (!all && store.hasOpenWorker(id)) continue;
    store.queueCleanup(id);
    queued++;
  }
  return queued;
}
