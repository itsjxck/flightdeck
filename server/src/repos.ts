// Finds the Git repositories on this machine, so coordinators know every
// repository without one having to be opened first. Walks the configured
// roots (default: your home folder) to a depth limit, skipping system and
// build folders, and stops at each repository (no repositories inside
// repositories). Worktrees (`.git` is a file) aren't repositories.
//
// Configured by `<data dir>/repos.json` (optional):
//   { "roots": ["~"], "maxDepth": 5, "skip": ["~/go/pkg"] }
// Repositories you don't want agents to use are ignored from Mission
// control's Repos tab; that is stored in the database, not here.
import { readdir } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { homedir } from "node:os";

export interface ScanConfig { roots: string[]; maxDepth: number; skip: string[] }

// Folder names never worth descending into.
const SKIP_NAMES: Record<string, true> = {
  Library: true, Applications: true, Movies: true, Music: true, Pictures: true, Public: true,
  node_modules: true, vendor: true, target: true, dist: true, build: true, worktrees: true,
};

const expand = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p);

export function loadConfig(dataDir: string): ScanConfig {
  const file = join(dataDir, "repos.json");
  let raw: Partial<ScanConfig> = {};
  if (existsSync(file)) raw = JSON.parse(readFileSync(file, "utf8")) as Partial<ScanConfig>;
  return {
    roots: (raw.roots ?? ["~"]).map(expand),
    maxDepth: raw.maxDepth ?? 5,
    skip: (raw.skip ?? ["~/go/pkg"]).map(expand),
  };
}

// Every repository under the roots, shallowest first: { name (its folder's name), path }.
export async function scanRepos(config: ScanConfig): Promise<{ name: string; path: string }[]> {
  const found: { name: string; path: string }[] = [];
  const skip = new Set(config.skip);
  let level = config.roots.filter((r) => existsSync(r));
  for (let depth = 0; depth <= config.maxDepth && level.length; depth++) {
    const next: string[] = [];
    await Promise.all(level.map(async (dir) => {
      let entries;
      try { entries = await readdir(dir, { withFileTypes: true }); } catch { return; }
      if (entries.some((e) => e.name === ".git" && e.isDirectory())) {
        found.push({ name: basename(dir), path: dir });
        return;
      }
      for (const e of entries) {
        if (!e.isDirectory() || e.name.startsWith(".") || SKIP_NAMES[e.name]) continue;
        const child = join(dir, e.name);
        if (!skip.has(child)) next.push(child);
      }
    }));
    level = next;
  }
  // Breadth-first already; sort within a depth so a rescan finds the same order.
  return found.sort((a, b) => a.path.split("/").length - b.path.split("/").length || a.path.localeCompare(b.path));
}

// ── One repository's worktrees (Mission control's Repos details) ────────────

export interface WorktreeInfo {
  branch: string | null; path: string; main: boolean; dirty: boolean; added: number; deleted: number;
  ahead: number; behind: number; conflicts: boolean; upstream: { ahead: number; behind: number } | null;
  head: { sha: string; subject: string; at: string } | null;
}

const WT = Bun.which("wt") ?? ["/opt/homebrew/bin/wt", "/usr/local/bin/wt", join(homedir(), ".cargo/bin/wt")].find((p) => existsSync(p)) ?? "wt";

type WtItem = {
  branch?: string | null;
  head?: { short_sha?: string; subject?: string; committed_at?: string };
  worktree?: { path?: string; main?: boolean; changes?: Record<string, unknown> & { diff?: { added?: number; deleted?: number } } };
  default_branch?: { ahead?: number; behind?: number; merge_conflicts?: boolean };
  upstream?: { ahead?: number; behind?: number };
};

// The repository's worktrees, from `wt list --format=json`: branch, changes,
// ahead/behind its default branch and upstream, last commit. Branches without a
// worktree are left out.
export async function repoInfo(path: string): Promise<{ defaultBranch: string | null; url: string | null; worktrees: WorktreeInfo[] }> {
  const p = Bun.spawn([WT, "-C", path, "list", "--format=json"], { stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new Error(`wt list failed: ${err.trim().split("\n").at(-1) ?? code}`);
  const data = JSON.parse(out) as { repo?: { default_branch?: string; forge?: { url?: string } }; items?: WtItem[] };
  const worktrees: WorktreeInfo[] = [];
  for (const i of data.items ?? []) {
    if (!i.worktree?.path) continue;
    const ch = i.worktree.changes ?? {};
    worktrees.push({
      branch: i.branch ?? null, path: i.worktree.path, main: i.worktree.main === true,
      dirty: ["staged", "modified", "untracked", "renamed", "deleted"].some((k) => ch[k] === true),
      added: ch.diff?.added ?? 0, deleted: ch.diff?.deleted ?? 0,
      ahead: i.default_branch?.ahead ?? 0, behind: i.default_branch?.behind ?? 0, conflicts: i.default_branch?.merge_conflicts === true,
      upstream: i.upstream ? { ahead: i.upstream.ahead ?? 0, behind: i.upstream.behind ?? 0 } : null,
      head: i.head ? { sha: i.head.short_sha ?? "", subject: i.head.subject ?? "", at: i.head.committed_at ?? "" } : null,
    });
  }
  return { defaultBranch: data.repo?.default_branch ?? null, url: data.repo?.forge?.url ?? null, worktrees };
}
