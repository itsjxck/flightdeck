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
