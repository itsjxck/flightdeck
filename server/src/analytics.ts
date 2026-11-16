// Mission control's Stats tab: what omp spends, how many agents run, and
// how goals and tasks end.
//
// - Spend: omp writes each model reply's usage (tokens, cost in USD) to its
//   session files (~/.omp/agent/sessions/<project>/<time>_<session>.jsonl, a
//   session's subagents in a folder of the same name). `scanUsage` reads only
//   what's new since the last scan (byte offset per file) into `usage`, per
//   file, local day and model.
// - Agents: the window posts a sample a minute (`agent_samples`).
// - Goals and tasks: from the store's own tables (the 30-day cleanup bounds them).
import { readdir, stat } from "node:fs/promises";
import { join, relative } from "node:path";
import { homedir } from "node:os";
import type { Store } from "./store";

// FLIGHTDECK_OMP_SESSIONS points it elsewhere (the screenshot demo).
const SESSIONS = process.env.FLIGHTDECK_OMP_SESSIONS ?? join(homedir(), ".omp/agent/sessions");
const SESSION_ID = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/;
const DAY_MS = 86_400_000;

export const ANALYTICS_SCHEMA = `
create table if not exists usage_files (path text primary key, offset integer not null, session text, cwd text);
create table if not exists usage (path text not null, day text not null, model text not null,
  cost real not null, tokens integer not null, primary key (path, day, model));
create table if not exists agent_samples (at integer primary key, total integer not null, working integer not null, waiting integer not null);
`;

// YYYY-MM-DD in local time.
export function localDay(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

async function jsonlFiles(dir: string, out: string[] = []): Promise<string[]> {
  let entries;
  try { entries = await readdir(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) await jsonlFiles(p, out);
    else if (e.name.endsWith(".jsonl")) out.push(p);
  }
  return out;
}

// Adds the usage in `lines` (complete JSONL lines) to `into`, keyed day|model. Pure.
export function addUsage(lines: string[], into: Map<string, { cost: number; tokens: number }>): { cwd?: string } {
  let cwd: string | undefined;
  for (const line of lines) {
    if (!line.includes('"usage"') && !line.includes('"type":"session"')) continue;
    let e: { type?: string; cwd?: string; timestamp?: string; message?: { model?: string; usage?: { totalTokens?: number; cost?: { total?: number } } } };
    try { e = JSON.parse(line); } catch { continue; }
    if (e.type === "session" && e.cwd) cwd = e.cwd;
    const u = e.message?.usage;
    if (!u?.cost || !e.timestamp) continue;
    const key = `${localDay(Date.parse(e.timestamp))}|${e.message?.model ?? "unknown"}`;
    const acc = into.get(key) ?? { cost: 0, tokens: 0 };
    acc.cost += u.cost.total ?? 0;
    acc.tokens += u.totalTokens ?? 0;
    into.set(key, acc);
  }
  return { cwd };
}

// Reads new usage from every session file. Returns how many files changed.
export async function scanUsage(store: Store, root = SESSIONS): Promise<number> {
  let changed = 0;
  for (const path of await jsonlFiles(root)) {
    let size: number;
    try { size = (await stat(path)).size; } catch { continue; }
    const known = store.db.query("select offset from usage_files where path = ?").get(path) as { offset: number } | null;
    const from = known?.offset ?? 0;
    if (size <= from) continue;
    const text = await Bun.file(path).slice(from, size).text();
    const end = text.lastIndexOf("\n");
    if (end < 0) continue; // no complete line yet
    const acc = new Map<string, { cost: number; tokens: number }>();
    const { cwd } = addUsage(text.slice(0, end).split("\n"), acc);
    // The session a file belongs to: the first session id in its path under the project folder (subagents nest under it).
    const session = SESSION_ID.exec(relative(root, path))?.[1] ?? null;
    store.db.transaction(() => {
      for (const [key, v] of acc) {
        const [day, model] = key.split("|");
        store.db.query(`insert into usage (path, day, model, cost, tokens) values (?, ?, ?, ?, ?)
          on conflict(path, day, model) do update set cost = cost + excluded.cost, tokens = tokens + excluded.tokens`)
          .run(path, day, model, v.cost, v.tokens);
      }
      store.db.query(`insert into usage_files (path, offset, session, cwd) values (?, ?, ?, ?)
        on conflict(path) do update set offset = excluded.offset, cwd = coalesce(usage_files.cwd, excluded.cwd)`)
        .run(path, from + Buffer.byteLength(text.slice(0, end + 1)), session, cwd ?? null);
    })();
    changed++;
  }
  return changed;
}

export function recordSample(store: Store, s: { total: number; working: number; waiting: number }, at = Date.now()) {
  store.db.query("insert or replace into agent_samples (at, total, working, waiting) values (?, ?, ?, ?)").run(at, s.total, s.working, s.waiting);
  store.db.query("delete from agent_samples where at < ?").run(at - 30 * DAY_MS);
}

// The project a session worked in: a known repository (its checkout or a ~/worktrees/<repo>/ worktree), else its folder's name.
function projectOf(cwd: string | null, repos: { name: string; path: string }[]): string {
  if (!cwd) return "unknown";
  for (const r of repos) if (cwd === r.path || cwd.startsWith(r.path + "/")) return r.name;
  const wt = /\/worktrees\/([^/]+)\//.exec(cwd + "/");
  if (wt) return wt[1];
  return cwd.split("/").filter(Boolean).at(-1) ?? "unknown";
}

// Everything the Stats tab shows. `days`: how far back the per-day series go.
export function analytics(store: Store, days = 14) {
  const now = Date.now();
  const since = localDay(now - (days - 1) * DAY_MS);
  const today = localDay(now);
  const dayList: string[] = [];
  for (let i = days - 1; i >= 0; i--) dayList.push(localDay(now - i * DAY_MS));

  const spendRows = store.db.query("select day, sum(cost) as cost, sum(tokens) as tokens from usage where day >= ? group by day").all(since) as { day: string; cost: number; tokens: number }[];
  // Each day's projects, for the bar's tooltip.
  const repoList = store.repos({ ignored: true });
  const dayProjects = new Map<string, Map<string, number>>();
  for (const r of store.db.query(`select u.day as day, f.cwd as cwd, sum(u.cost) as cost from usage u join usage_files f on f.path = u.path
      where u.day >= ? group by u.day, f.cwd`).all(since) as { day: string; cwd: string | null; cost: number }[]) {
    const m = dayProjects.get(r.day) ?? new Map<string, number>();
    const p = projectOf(r.cwd, repoList);
    m.set(p, (m.get(p) ?? 0) + r.cost);
    dayProjects.set(r.day, m);
  }
  const spendByDay = dayList.map((day) => ({
    day, cost: spendRows.find((r) => r.day === day)?.cost ?? 0, tokens: spendRows.find((r) => r.day === day)?.tokens ?? 0,
    projects: [...(dayProjects.get(day) ?? [])].map(([project, cost]) => ({ project, cost })).sort((a, b) => b.cost - a.cost).slice(0, 4),
  }));
  const total = (from: string) => {
    const row = store.db.query("select coalesce(sum(cost), 0) as c, coalesce(sum(tokens), 0) as t from usage where day >= ?").get(from) as { c: number; t: number };
    return row;
  };
  const monthTotal = total(localDay(now - 29 * DAY_MS));
  const spend = { today: total(today).c, week: total(localDay(now - 6 * DAY_MS)).c, month: monthTotal.c, monthTokens: monthTotal.t };

  const month = localDay(now - 29 * DAY_MS);
  const byModel = store.db.query("select model, sum(cost) as cost, sum(tokens) as tokens from usage where day >= ? group by model order by cost desc").all(month) as { model: string; cost: number; tokens: number }[];
  const repos = store.repos({ ignored: true });
  const projectCost = new Map<string, number>();
  for (const r of store.db.query(`select f.cwd as cwd, sum(u.cost) as cost from usage u join usage_files f on f.path = u.path
      where u.day >= ? group by f.cwd`).all(month) as { cwd: string | null; cost: number }[]) {
    const p = projectOf(r.cwd, repos);
    projectCost.set(p, (projectCost.get(p) ?? 0) + r.cost);
  }
  const byProject = [...projectCost].map(([project, cost]) => ({ project, cost })).sort((a, b) => b.cost - a.cost);

  // Each goal's spend: its tasks' sessions (coordinator and workers), with their subagents.
  const byGoal = (store.db.query(`select g.id, g.title, g.status, count(distinct t.id) as tasks, coalesce(sum(u.cost), 0) as cost
      from goals g left join tasks t on t.goal = g.id left join usage_files f on f.session = t.session
      left join usage u on u.path = f.path group by g.id order by g.id desc limit 12`).all() as
      { id: number; title: string; status: string; tasks: number; cost: number }[]).map((g) => ({ ...g, ref: `G${g.id}` }));

  const finished = store.db.query(`select id, title, status, updated from tasks where status in ('done', 'failed', 'dropped') and updated >= ?`)
    .all(now - days * DAY_MS) as { id: number; title: string; status: string; updated: number }[];
  const tasksByDay = dayList.map((day) => {
    const ofDay = finished.filter((t) => localDay(t.updated) === day && t.status !== "dropped");
    return {
      day,
      done: ofDay.filter((t) => t.status === "done").length,
      failed: ofDay.filter((t) => t.status === "failed").length,
      // For the bar's tooltip.
      titles: ofDay.slice(0, 6).map((t) => `${store.tref(t.id)} ${t.title}${t.status === "failed" ? " (failed)" : ""}`),
    };
  });
  const count = (sql: string) => {
    // bun:sqlite rows are untyped; every query here selects `count(*) as n`.
    const row = store.db.query(sql).get() as { n: number };
    return row.n;
  };
  const totals = {
    tasksDone: count("select count(*) as n from tasks where status = 'done'"),
    tasksFailed: count("select count(*) as n from tasks where status = 'failed'"),
    tasksOpen: count("select count(*) as n from tasks where status in ('todo', 'ready', 'doing')"),
    goalsDone: count("select count(*) as n from goals where status = 'done'"),
    goalsDropped: count("select count(*) as n from goals where status = 'dropped'"),
    goalsActive: count("select count(*) as n from goals where status in ('active', 'finished')"),
  };

  // Agents over the last 24 hours, the busiest sample of each hour.
  const samples = store.db.query("select at, total, working, waiting from agent_samples where at >= ? order by at").all(now - DAY_MS) as
    { at: number; total: number; working: number; waiting: number }[];
  const hours: { hour: string; working: number; total: number; waiting: number }[] = [];
  for (let i = 23; i >= 0; i--) {
    const start = now - (i + 1) * 3_600_000, end = now - i * 3_600_000;
    const inHour = samples.filter((s) => s.at >= start && s.at < end);
    hours.push({ hour: String(new Date(end).getHours()).padStart(2, "0") + ":00",
      working: Math.max(0, ...inHour.map((s) => s.working)), total: Math.max(0, ...inHour.map((s) => s.total)),
      waiting: Math.max(0, ...inHour.map((s) => s.waiting)) });
  }
  const latest = samples.at(-1) ?? null;

  return { now, spend, spendByDay, byModel, byProject, byGoal, tasksByDay, totals, agentsByHour: hours, agentsNow: latest };
}
