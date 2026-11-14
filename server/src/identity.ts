// Which omp session is calling: the server gets the caller's Tern pane id
// (X-Tern-Pane), asks Tern for the pane's process, and reads the session id
// from the session file omp keeps open (`…_<session id>.jsonl`), else from
// `--resume <id>` / `--restore <file>` on its command line.
import { basename, dirname } from "node:path";
import type { Caller } from "./store";

const SESSION_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
const TERN = process.env.TERN_EXE || "/Applications/Tern.app/Contents/MacOS/tern";
const CACHE_MS = 30_000;
// A fresh omp opens its session file on its first message, a moment after
// Overseer starts asking about its pane: misses expire fast.
const MISS_MS = 2_000;

export function sessionFromArgv(argv: string[]): string | null {
  const i = argv.findIndex((a) => a === "--resume" || a === "--restore");
  const m = i >= 0 ? SESSION_ID.exec(basename(argv[i + 1] ?? "")) : null;
  return m ? m[0] : null;
}

// The omp session file open in `lsof -Fpn` output, and the pid holding it.
export function sessionFromLsof(output: string): { session: string; pid: string } | null {
  let pid = "";
  for (const line of output.split("\n")) {
    if (line.startsWith("p")) pid = line.slice(1);
    else if (line.startsWith("n") && line.includes("/.omp/") && line.includes("/sessions/") && line.endsWith(".jsonl")) {
      const m = SESSION_ID.exec(basename(line));
      if (m) return { session: m[0], pid };
    }
  }
  return null;
}

function cwdOf(pid: string): string | null {
  const line = run(["/usr/sbin/lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"]).split("\n").find((l) => l.startsWith("n"));
  return line ? line.slice(1) : null;
}

export function repoName(commonGitDir: string): string {
  return basename(dirname(commonGitDir));
}

export function repoRoot(commonGitDir: string): string {
  return dirname(commonGitDir);
}

function run(cmd: string[]): string {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "ignore" });
  return r.stdout.toString();
}

interface PaneProcess { pid?: number; group?: number; argv?: string[]; cwd?: string }

function paneProcess(pane: string): PaneProcess | null {
  try {
    const info: unknown = JSON.parse(run([TERN, "process", pane, "--json"]));
    if (!info || typeof info !== "object") return null;
    const proc = ("foreground" in info ? info.foreground : undefined) ?? ("child" in info ? info.child : undefined);
    if (!proc || typeof proc !== "object") return null;
    const group = "group" in info && typeof info.group === "number" ? info.group : undefined;
    return { ...(proc as PaneProcess), group };
  } catch {
    return null;
  }
}

// Misses are cached too: Overseer asks about every shell pane every 2 s.
const cache = new Map<string, { at: number; caller: Caller | null }>();

// The omp session in `pane`, with its folder, repository and branch; null when the pane runs no omp session.
export function resolvePane(pane: string): Caller | null {
  const hit = cache.get(pane);
  if (hit && Date.now() - hit.at < (hit.caller ? CACHE_MS : MISS_MS)) return hit.caller;
  const caller = lookup(pane);
  cache.set(pane, { at: Date.now(), caller });
  return caller;
}

function lookup(pane: string): Caller | null {
  const proc = paneProcess(pane);
  if (!proc?.pid) return null;
  // The whole process group: a worker's pane runs Worktrunk, with omp as its child.
  const select = proc.group ? ["-g", String(proc.group)] : ["-p", String(proc.pid)];
  const open = sessionFromLsof(run(["/usr/sbin/lsof", "-a", ...select, "-Fpn"]));
  const session = open?.session ?? sessionFromArgv(proc.argv ?? []);
  if (!session) return null;
  // omp's own folder (a worker's worktree), not Worktrunk's.
  const cwd = (open && open.pid !== String(proc.pid) ? cwdOf(open.pid) : null) ?? proc.cwd ?? null;
  let repo: string | null = null, branch: string | null = null, root: string | null = null;
  if (cwd) {
    const common = run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"]).trim();
    if (common) {
      repo = repoName(common);
      root = repoRoot(common);
      branch = run(["git", "-C", cwd, "branch", "--show-current"]).trim() || null;
    }
  }
  return { session, repo, branch, cwd, root };
}
