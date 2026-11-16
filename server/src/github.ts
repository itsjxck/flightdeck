// GitHub issues, through the `gh` CLI (already signed in; no token of ours).
// Lists open issues of every known, non-ignored repository with a GitHub
// remote, comments on issues linked to goals, and closes one when you ask.
// Flightdeck never closes issues on its own: PRs close them with GitHub's
// closing keywords ("Fixes owner/repo#12").
import { existsSync } from "node:fs";

export interface Issue {
  repo: string;       // owner/name
  local: string;      // the repository's name in Flightdeck (its folder)
  number: number;
  title: string;
  body: string;
  url: string;
  labels: string[];
  updatedAt: string;
}

const GH = Bun.which("gh") ?? ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].find((p) => existsSync(p)) ?? "gh";
const LIST_LIMIT = 50;

async function run(cmd: string[], cwd?: string): Promise<{ ok: boolean; out: string; err: string }> {
  const p = Bun.spawn(cmd, { cwd, stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { ok: code === 0, out, err: err.trim() };
}

// owner/name from a GitHub remote URL (ssh or https); null for other hosts.
export function githubRepo(remote: string): string | null {
  const m = /github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(remote.trim());
  return m ? `${m[1]}/${m[2]}` : null;
}

// "owner/name#12" (or a github.com issue URL) → its parts; null otherwise.
export function parseIssueRef(ref: string): { repo: string; number: number } | null {
  const m = /^([\w.-]+\/[\w.-]+)#(\d+)$/.exec(ref.trim()) ?? /github\.com\/([\w.-]+\/[\w.-]+)\/issues\/(\d+)/.exec(ref);
  return m ? { repo: m[1], number: Number(m[2]) } : null;
}

// The open issues of `repos` (Flightdeck name → folder), newest activity first.
export async function listIssues(repos: { name: string; path: string }[]): Promise<{ issues: Issue[]; errors: string[] }> {
  const errors: string[] = [];
  const lists = await Promise.all(repos.map(async (r) => {
    const remote = await run(["git", "-C", r.path, "remote", "get-url", "origin"]);
    const gh = remote.ok ? githubRepo(remote.out) : null;
    if (!gh) return [];
    const res = await run([GH, "issue", "list", "-R", gh, "--state", "open", "--limit", String(LIST_LIMIT),
      "--json", "number,title,body,url,labels,updatedAt"]);
    if (!res.ok) {
      // Repositories with issues turned off simply have none.
      if (!res.err.includes("has disabled issues")) errors.push(`${gh}: ${res.err}`);
      return [];
    }
    const raw = JSON.parse(res.out) as { number: number; title: string; body: string; url: string; labels: { name: string }[]; updatedAt: string }[];
    return raw.map((i) => ({ repo: gh, local: r.name, number: i.number, title: i.title, body: i.body, url: i.url,
      labels: i.labels.map((l) => l.name), updatedAt: i.updatedAt }));
  }));
  return { issues: lists.flat().sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)), errors };
}

export interface PullRequest { number: number; state: "OPEN" | "MERGED" | "CLOSED"; url: string; title: string }

// The newest PR whose head is `branch` in owner/name, or null (none, or gh failed).
export async function prForBranch(repo: string, branch: string): Promise<PullRequest | null> {
  const res = await run([GH, "pr", "list", "-R", repo, "--head", branch, "--state", "all", "--limit", "1", "--json", "number,state,url,title"]);
  if (!res.ok) return null;
  const list = JSON.parse(res.out) as PullRequest[];
  return list[0] ?? null;
}

export async function comment(repo: string, number: number, body: string): Promise<string | null> {
  const res = await run([GH, "issue", "comment", String(number), "-R", repo, "--body", body]);
  return res.ok ? null : res.err;
}

// Comments on every issue linked to a goal, in the background; failures are logged, not raised.
export function commentAll(issues: { repo: string; number: number }[], body: string) {
  for (const i of issues) {
    comment(i.repo, i.number, body).then((err) => { if (err) console.error(`comment on ${i.repo}#${i.number} failed: ${err}`); });
  }
}

// Closes an issue you chose to close: "completed" or "not planned".
export async function closeIssue(repo: string, number: number, reason: "completed" | "not planned"): Promise<string | null> {
  const res = await run([GH, "issue", "close", String(number), "-R", repo, "--reason", reason]);
  return res.ok ? null : res.err;
}
