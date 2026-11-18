// flightdeck-server's data and every rule: tasks, goals, dependencies,
// questions, messages, workers and deliveries. SQLite only, no other I/O,
// so the MCP tools and Flightdeck's HTTP API share the same behaviour.
import { Database } from "bun:sqlite";
import { ANALYTICS_SCHEMA } from "./analytics";
import { existsSync } from "node:fs";

export type TaskStatus = "todo" | "ready" | "doing" | "done" | "failed" | "dropped";
// finished: the coordinator has reported (its own task is done); the goal stays on
// screen for review until the user closes it (done).
export type GoalStatus = "proposed" | "active" | "finished" | "done" | "dropped";
export type EventKind = "note" | "question" | "answer" | "message" | "done" | "status";

export interface Task {
  id: number; goal: number | null; title: string; body: string; repo: string | null;
  branch: string | null; worktree: string | null; pr: string | null; status: TaskStatus;
  readonly: number; session: string | null; started_by: string | null; created: number; updated: number;
}
export interface Goal {
  id: number; title: string; body: string; coordinator: string | null;
  tern_session: string | null; status: GoalStatus; created: number;
  // When it was closed (done or dropped); null while open.
  closed: number | null;
}
export interface Event {
  id: number; task: number | null; goal: number | null; author: string; kind: EventKind;
  body: string; options: string | null; recommended: number | null; to_target: string | null;
  created: number; delivered: number | null; handled: number | null;
}
export interface Worker {
  id: number; task: number; goal: number; requested_by: string;
  status: "requested" | "started" | "stopping" | "stopped" | "failed"; pane: string | null; created: number;
  // What the coordinator wants this worker to know, added to its brief.
  context: string | null;
}
export interface Caller { session: string; repo: string | null; branch: string | null; cwd: string | null; root?: string | null }

export const MAX_WORKERS = 4;
export const AGENT_MESSAGE_GAP = 120_000;
// A coordinator looping on inbox reads it every 25 s at most; one that left
// its inbox unread this long has ended its turn, so the items go to its pane.
export const COORDINATOR_WAKE_MS = 120_000;

const SCHEMA = `
create table if not exists goals (
  id integer primary key, title text not null, body text not null default '',
  coordinator text, tern_session text, status text not null, created integer not null, closed integer);
create table if not exists tasks (
  id integer primary key, goal integer references goals(id), title text not null,
  body text not null default '', repo text, branch text, worktree text, pr text,
  status text not null, readonly integer not null default 0, session text,
  started_by text, created integer not null, updated integer not null, seq integer not null default 0);
create table if not exists deps (
  task integer not null references tasks(id), needs integer not null references tasks(id),
  primary key (task, needs));
create table if not exists events (
  id integer primary key, task integer references tasks(id), goal integer references goals(id),
  author text not null, kind text not null, body text not null, options text, recommended integer,
  to_target text, created integer not null, delivered integer, handled integer);
create table if not exists workers (
  id integer primary key, task integer not null references tasks(id), goal integer not null references goals(id),
  requested_by text not null, status text not null, pane text, created integer not null, context text);
create table if not exists goal_issues (
  goal integer not null references goals(id), repo text not null, number integer not null,
  title text not null default '', url text not null default '', primary key (goal, repo, number));
create table if not exists cleanups (task integer primary key references tasks(id), queued integer not null, done integer);
create table if not exists counters (name text primary key, value integer not null);
create table if not exists goal_branches (goal integer not null references goals(id), repo text not null, branch text not null,
  primary key (goal, repo));
create table if not exists repos (name text primary key, path text not null,
  source text not null default 'learned', ignored integer not null default 0,
  issues_ignored integer not null default 0);
`;

type PlanTask = { key: string; title: string; body?: string; repo: string; needs?: string[]; readonly?: boolean };

export class Store {
  readonly db: Database;

  constructor(path: string, readonly now: () => number = Date.now) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec("pragma journal_mode = wal; pragma foreign_keys = on;");
    this.db.exec(SCHEMA);
    this.db.exec(ANALYTICS_SCHEMA);
    // Added after the first release: databases created before it lack the column.
    const cols = this.db.query("select name from pragma_table_info('workers')").all() as { name: string }[];
    if (!cols.some((c) => c.name === "context")) this.db.exec("alter table workers add column context text");
    const repoCols = this.db.query("select name from pragma_table_info('repos')").all() as { name: string }[];
    if (!repoCols.some((c) => c.name === "ignored")) {
      this.db.exec("alter table repos add column source text not null default 'learned'");
      this.db.exec("alter table repos add column ignored integer not null default 0");
    }
    const taskCols = this.db.query("select name from pragma_table_info('tasks')").all() as { name: string }[];
    if (!taskCols.some((c) => c.name === "seq")) {
      // Number existing tasks: within each goal (its coordinator's task 0), then outside goals, by age.
      this.db.exec("alter table tasks add column seq integer not null default 0");
      this.db.exec(`update tasks set seq = (select count(*) from tasks o where o.goal = tasks.goal and o.id <= tasks.id
          and o.session is not (select coordinator from goals where id = tasks.goal))
        where goal is not null and session is not (select coordinator from goals where id = tasks.goal)`);
      this.db.exec("update tasks set seq = (select count(*) from tasks o where o.goal is null and o.id <= tasks.id) where goal is null");
      this.db.exec("insert or ignore into counters (name, value) select 'loose', coalesce(max(seq), 0) from tasks where goal is null");
      this.db.exec("insert or ignore into counters (name, value) select 'goal', coalesce(max(id), 0) from goals");
    }
    const goalCols = this.db.query("select name from pragma_table_info('goals')").all() as { name: string }[];
    if (!goalCols.some((c) => c.name === "closed")) this.db.exec("alter table goals add column closed integer");
    if (!repoCols.some((c) => c.name === "issues_ignored")) this.db.exec("alter table repos add column issues_ignored integer not null default 0");
  }

  // References people and agents use. Goals: G3. A goal's tasks are numbered
  // within it: G3.1, G3.2 (G3.0 is its coordinator's own task). Tasks outside
  // goals: T7. Numbers only grow (counters survive the 30-day cleanup).
  // The first release's forms (G-3, T-12 = internal id) are still accepted.
  static gid(id: number) { return `G${id}`; }
  static wid(id: number) { return `W${id}`; }
  static parseGoal(ref: string): number {
    const m = /^G-?(\d+)$/i.exec(ref.trim());
    if (!m) throw new Error(`'${ref}' is not a goal id (G3)`);
    return Number(m[1]);
  }

  tref(id: number): string {
    const t = this.db.query("select goal, seq from tasks where id = ?").get(id) as { goal: number | null; seq: number } | null;
    if (!t) throw new Error(`no task with internal id ${id}`);
    return t.goal != null ? `G${t.goal}.${t.seq}` : `T${t.seq}`;
  }

  taskId(ref: string): number {
    const r = ref.trim();
    let m = /^G-?(\d+)\.(\d+)$/i.exec(r);
    if (m) {
      const row = this.db.query("select id from tasks where goal = ? and seq = ?").get(Number(m[1]), Number(m[2])) as { id: number } | null;
      if (!row) throw new Error(`no task ${r}`);
      return row.id;
    }
    m = /^T(\d+)$/i.exec(r);
    if (m) {
      const row = this.db.query("select id from tasks where goal is null and seq = ?").get(Number(m[1])) as { id: number } | null;
      if (!row) throw new Error(`no task ${r}`);
      return row.id;
    }
    m = /^T-(\d+)$/i.exec(r);
    if (m) return Number(m[1]);
    throw new Error(`'${ref}' is not a task id (G3.2, or T7 outside goals)`);
  }

  // The next number of a sequence that never goes back ("goal", "loose").
  private next(name: string, floor: number): number {
    const row = this.db.query("select value from counters where name = ?").get(name) as { value: number } | null;
    const value = Math.max(row?.value ?? 0, floor) + 1;
    this.db.query("insert into counters (name, value) values (?, ?) on conflict(name) do update set value = excluded.value").run(name, value);
    return value;
  }

  // A new task's number: within its goal, or among tasks outside goals.
  private nextSeq(goal: number | null): number {
    if (goal == null) {
      const max = this.db.query("select coalesce(max(seq), 0) as m from tasks where goal is null").get() as { m: number };
      return this.next("loose", max.m);
    }
    const max = this.db.query("select coalesce(max(seq), 0) as m from tasks where goal = ?").get(goal) as { m: number };
    return max.m + 1;
  }

  // ── Tasks ──────────────────────────────────────────────────────────────

  listTasks(filter: { goal?: number; repo?: string; status?: TaskStatus; session?: string }): Task[] {
    const where: string[] = [], args: (string | number)[] = [];
    if (filter.goal != null) { where.push("goal = ?"); args.push(filter.goal); }
    if (filter.repo != null) { where.push("repo = ?"); args.push(filter.repo); }
    if (filter.status != null) { where.push("status = ?"); args.push(filter.status); }
    if (filter.session != null) { where.push("session = ?"); args.push(filter.session); }
    const sql = `select * from tasks ${where.length ? "where " + where.join(" and ") : ""} order by id`;
    return this.db.query(sql).all(...args) as Task[];
  }

  task(id: number): Task {
    const t = this.db.query("select * from tasks where id = ?").get(id) as Task | null;
    if (!t) throw new Error(`${this.tref(id)} doesn't exist`);
    return t;
  }

  events(task: number): Event[] {
    return this.db.query("select * from events where task = ? order by id").all(task) as Event[];
  }

  private touch(id: number, fields: Partial<Task>) {
    const entries = Object.entries(fields) as [string, string | number | null][];
    const sets = [...entries.map(([k]) => `${k} = ?`), "updated = ?"].join(", ");
    this.db.query(`update tasks set ${sets} where id = ?`)
      .run(...entries.map(([, v]) => v), this.now(), id);
  }

  addEvent(e: Omit<Event, "id" | "created" | "delivered" | "handled">): Event {
    return this.db.query(`insert into events (task, goal, author, kind, body, options, recommended, to_target, created)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?) returning *`)
      .get(e.task, e.goal, e.author, e.kind, e.body, e.options, e.recommended, e.to_target, this.now()) as Event;
  }

  addTask(_caller: Caller, a: { title: string; body?: string; repo: string; goal?: number; needs?: number[]; readonly?: boolean }): Task {
    const now = this.now();
    const t = this.db.query(`insert into tasks (goal, title, body, repo, status, readonly, created, updated, seq)
      values (?, ?, ?, ?, 'todo', ?, ?, ?, ?) returning *`)
      .get(a.goal ?? null, a.title, a.body ?? "", a.repo, a.readonly ? 1 : 0, now, now, this.nextSeq(a.goal ?? null)) as Task;
    for (const need of a.needs ?? []) {
      this.task(need);
      this.db.query("insert into deps (task, needs) values (?, ?)").run(t.id, need);
    }
    this.promote(t.id);
    return this.task(t.id);
  }

  // Each task's dependencies both ways, for people and agents: what it waits
  // on (with their status) and what waits on it, by reference.
  dependencies(): Map<number, { needs: { ref: string; status: TaskStatus }[]; blocks: { ref: string; status: TaskStatus }[] }> {
    const rows = this.db.query(`select d.task as task, d.needs as needs, a.status as taskStatus, b.status as needsStatus
      from deps d join tasks a on a.id = d.task join tasks b on b.id = d.needs`).all() as
      { task: number; needs: number; taskStatus: TaskStatus; needsStatus: TaskStatus }[];
    const out = new Map<number, { needs: { ref: string; status: TaskStatus }[]; blocks: { ref: string; status: TaskStatus }[] }>();
    const of = (id: number) => { let e = out.get(id); if (!e) { e = { needs: [], blocks: [] }; out.set(id, e); } return e; };
    for (const r of rows) {
      of(r.task).needs.push({ ref: this.tref(r.needs), status: r.needsStatus });
      of(r.needs).blocks.push({ ref: this.tref(r.task), status: r.taskStatus });
    }
    return out;
  }

  // "waits on G2.1 (doing)" / "holds up G2.2, G2.3": a task's open dependencies in words, for agents' tool output.
  dependencyText(task: number, deps = this.dependencies()): string {
    const d = deps.get(task);
    if (!d) return "";
    const done = ["done", "dropped"];
    const waits = d.needs.filter((n) => !done.includes(n.status)).map((n) => `${n.ref} (${n.status})`);
    const t = this.task(task);
    const holds = done.includes(t.status) ? [] : d.blocks.filter((b) => !done.includes(b.status)).map((b) => b.ref);
    return [waits.length ? `waits on ${waits.join(", ")}` : "", holds.length ? `holds up ${holds.join(", ")}` : ""].filter(Boolean).join("; ");
  }

  // A goal's todo task is ready once nothing it needs is unfinished.
  private promote(id: number) {
    const t = this.task(id);
    if (t.status !== "todo" || t.goal == null) return;
    const open = this.db.query(`select count(*) as n from deps d join tasks n on n.id = d.needs
      where d.task = ? and n.status != 'done'`).get(id) as { n: number };
    if (open.n === 0) this.touch(id, { status: "ready" });
  }

  startTask(caller: Caller, a: { id?: number; title?: string; body?: string; readonly?: boolean }): Task {
    if (a.id == null) {
      if (!a.title) throw new Error("task_start needs a title, or the id of a task to pick up");
      const now = this.now();
      return this.db.query(`insert into tasks (title, body, repo, branch, worktree, status, readonly, session, created, updated, seq)
        values (?, ?, ?, ?, ?, 'doing', ?, ?, ?, ?, ?) returning *`)
        .get(a.title, a.body ?? "", caller.repo, caller.branch, caller.cwd, a.readonly ? 1 : 0, caller.session, now, now, this.nextSeq(null)) as Task;
    }
    const t = this.task(a.id);
    const mine = t.session === caller.session;
    if (!mine && !["todo", "ready"].includes(t.status)) {
      throw new Error(`${this.tref(t.id)} is ${t.status}${t.session ? " and held by another agent" : ""}`);
    }
    this.touch(t.id, { status: "doing", session: caller.session, branch: caller.branch, worktree: caller.cwd });
    return this.task(t.id);
  }

  myTask(session: string, ref?: string): Task {
    if (ref) {
      const t = this.task(this.taskId(ref));
      if (t.session !== session) throw new Error(`${ref} is not yours; call task_start with its id first`);
      return t;
    }
    const doing = this.listTasks({ session, status: "doing" });
    if (doing.length === 0) throw new Error("you have no task in progress; call task_start first");
    if (doing.length > 1) throw new Error(`you have several tasks in progress (${doing.map((t) => this.tref(t.id)).join(", ")}); pass id`);
    return doing[0];
  }

  note(session: string, a: { ref?: string; body: string; pr?: string; answered?: boolean }): Task {
    const t = this.myTask(session, a.ref);
    this.touch(t.id, a.pr ? { pr: a.pr } : {});
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "note", body: a.body, options: null, recommended: null, to_target: null });
    // Answered in the agent's own pane: record it as the answer, already delivered.
    if (a.answered) {
      const e = this.addEvent({ task: t.id, goal: t.goal, author: "you", kind: "answer", body: a.body, options: null, recommended: null, to_target: null });
      this.markDelivered(e.id);
    }
    return this.task(t.id);
  }

  doneTask(session: string, a: { ref?: string; outcome: "succeeded" | "failed"; summary: string; files?: string[] }): Task {
    const t = this.myTask(session, a.ref);
    const own = t.goal != null ? this.goal(t.goal) : null;
    if (own && own.coordinator === t.session && own.status === "active") {
      throw new Error("you coordinate this goal: finish it with goal_complete once it's verified and cleaned up");
    }
    this.touch(t.id, { status: a.outcome === "succeeded" ? "done" : "failed" });
    const files = a.files?.length ? `\n\nFiles: ${a.files.map((f) => "`" + f + "`").join(", ")}` : "";
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "done", body: `**${a.outcome}:** ${a.summary}${files}`,
      options: null, recommended: null, to_target: t.goal != null ? "coordinator" : null });
    const dependents = this.db.query("select task from deps where needs = ?").all(t.id) as { task: number }[];
    for (const d of dependents) this.promote(d.task);
    this.finishGoalIfDone(t.goal);
    return this.task(t.id);
  }

  // A coordinator reshaping its plan. Title and body change any time; repo and
  // needs only before the task starts (needs replaces the list).
  editTask(goal: number, task: number, a: { title?: string; body?: string; repo?: string; needs?: number[] }) {
    const t = this.task(task);
    if (t.goal !== goal) throw new Error(`${this.tref(task)} isn't part of ${Store.gid(goal)}`);
    const started = !["todo", "ready"].includes(t.status);
    if (started && (a.repo != null || a.needs != null)) throw new Error(`${this.tref(task)} has started; only its title and body can change`);
    const fields: Partial<Task> = {};
    if (a.title != null) fields.title = a.title;
    if (a.body != null) fields.body = a.body;
    if (a.repo != null) fields.repo = a.repo;
    if (Object.keys(fields).length) this.touch(task, fields);
    if (a.needs != null) {
      for (const n of a.needs) if (this.task(n).goal !== goal) throw new Error(`${this.tref(n)} isn't part of ${Store.gid(goal)}`);
      this.db.query("delete from deps where task = ?").run(task);
      for (const n of a.needs) this.db.query("insert into deps (task, needs) values (?, ?)").run(task, n);
      // Re-derive readiness from the new needs.
      this.touch(task, { status: "todo" });
      this.promote(task);
    }
    return this.task(task);
  }

  setTaskPr(task: number, url: string) {
    this.touch(task, { pr: url });
  }

  // ── Worktree cleanup (cleanup.ts decides, the window removes) ──────────

  hasOpenWorker(task: number): boolean {
    return !!this.db.query("select 1 from workers where task = ? and status in ('requested', 'started', 'stopping')").get(task);
  }

  cleanupQueued(task: number): boolean {
    return !!this.db.query("select 1 from cleanups where task = ? and done is null").get(task);
  }

  // A coordinator asks to remove a finished task's worktree; the window does it
  // and the result comes back through the coordinator's inbox.
  requestWorktreeRemoval(caller: Caller, task: number): Task {
    const g = this.coordinatorGoalFor(caller.session);
    const t = this.task(task);
    if (t.goal !== g.id) throw new Error(`${this.tref(t.id)} isn't part of ${Store.gid(g.id)}`);
    if (t.session === g.coordinator) throw new Error("that's your own checkout");
    if (!["done", "failed", "dropped"].includes(t.status)) throw new Error(`${this.tref(t.id)} is ${t.status}; finish or drop it first`);
    if (this.hasOpenWorker(t.id)) throw new Error(`${this.tref(t.id)}'s worker is still open; close it with worker_stop first`);
    if (!t.worktree || t.worktree === this.repoPath(t.repo)) throw new Error(`${this.tref(t.id)} has no worktree of its own`);
    this.queueCleanup(t.id);
    return t;
  }

  queueCleanup(task: number) {
    this.db.query("insert into cleanups (task, queued) values (?, ?) on conflict(task) do update set queued = excluded.queued, done = null").run(task, this.now());
  }

  // Worktrees to remove: { task id, repository folder, branch, worktree }.
  pendingCleanups(): { id: number; repoPath: string | null; branch: string; worktree: string }[] {
    const rows = this.db.query(`select t.* from cleanups c join tasks t on t.id = c.task
      where c.done is null and t.worktree is not null and t.branch is not null`).all() as Task[];
    return rows.map((t) => ({ id: t.id, repoPath: this.repoPath(t.repo), branch: t.branch!, worktree: t.worktree! }));
  }

  // The window removed a queued worktree (ok) or couldn't (error): tell the goal's coordinator.
  cleanupDone(task: number, error?: string) {
    const t = this.task(task);
    this.db.query("update cleanups set done = ? where task = ?").run(this.now(), task);
    if (!error) this.touch(task, { worktree: null });
    if (t.goal != null && this.cleanupWasQueued(task)) {
      this.addEvent({ task: t.id, goal: t.goal, author: "flightdeck", kind: "status",
        body: error ? `Couldn't remove ${this.tref(t.id)}'s worktree (${t.worktree}): ${error}` : `Removed ${this.tref(t.id)}'s worktree and branch ${t.branch}.`,
        options: null, recommended: null, to_target: "coordinator" });
    }
  }

  private cleanupWasQueued(task: number): boolean {
    return !!this.db.query("select 1 from cleanups where task = ?").get(task);
  }

  // The coordinator ends the goal, once nothing is left: every task finished, no
  // worker open, no question waiting, and every worktree removed or kept with a reason.
  completeGoal(caller: Caller, a: { summary: string; keep?: { task: number; reason: string }[] }): Goal {
    const g = this.coordinatorGoalFor(caller.session);
    const problems: string[] = [];
    const kept = new Map((a.keep ?? []).map((k) => [k.task, k.reason]));
    for (const t of this.listTasks({ goal: g.id })) {
      if (t.session === g.coordinator) continue;
      const ref = this.tref(t.id);
      if (!["done", "failed", "dropped"].includes(t.status)) problems.push(`${ref} is ${t.status}`);
      if (this.hasOpenWorker(t.id)) problems.push(`${ref}'s worker is still open (worker_stop)`);
      if (t.worktree && t.worktree !== this.repoPath(t.repo) && existsSync(t.worktree) && !kept.has(t.id)) {
        problems.push(`${ref}'s worktree ${t.worktree} is still there (worktree_remove, or keep it with a reason)`);
      }
    }
    const waiting = this.waiting().filter((w) => w.task.goal === g.id);
    if (waiting.length) problems.push(`${waiting.length} question(s) still wait for the user: the goal isn't done while it needs their direction`);
    if (problems.length) throw new Error(`${Store.gid(g.id)} isn't done yet:\n- ${problems.join("\n- ")}`);
    const keptLines = [...kept].map(([task, reason]) => `- ${this.tref(task)}: worktree kept (${reason})`);
    const own = this.listTasks({ goal: g.id }).find((t) => t.session === g.coordinator && t.status === "doing");
    this.db.transaction(() => {
      if (own) {
        this.touch(own.id, { status: "done" });
        this.addEvent({ task: own.id, goal: g.id, author: caller.session, kind: "done",
          body: `**Goal complete:** ${a.summary}${keptLines.length ? "\n\n" + keptLines.join("\n") : ""}`, options: null, recommended: null, to_target: null });
      }
      this.closeGoal(g.id, "done");
    })();
    return this.goal(g.id);
  }

  dropTask(goal: number, task: number) {
    const t = this.task(task);
    if (t.goal !== goal) throw new Error(`${this.tref(task)} isn't part of ${Store.gid(goal)}`);
    if (t.status === "doing") throw new Error(`${this.tref(task)} has a worker; worker_stop it first`);
    this.touch(task, { status: "dropped" });
    this.finishGoalIfDone(goal);
  }

  // ── GitHub issues linked to goals (owner/name#number) ──────────────────

  linkIssue(goal: number, i: { repo: string; number: number; title?: string; url?: string }) {
    this.goal(goal);
    this.db.query(`insert into goal_issues (goal, repo, number, title, url) values (?, ?, ?, ?, ?)
      on conflict(goal, repo, number) do update set title = excluded.title, url = excluded.url`)
      .run(goal, i.repo, i.number, i.title ?? "", i.url || `https://github.com/${i.repo}/issues/${i.number}`);
  }

  unlinkIssue(goal: number, repo: string, number: number) {
    this.db.query("delete from goal_issues where goal = ? and repo = ? and number = ?").run(goal, repo, number);
  }

  goalIssues(goal: number): { repo: string; number: number; title: string; url: string }[] {
    return this.db.query("select repo, number, title, url from goal_issues where goal = ? order by repo, number").all(goal) as
      { repo: string; number: number; title: string; url: string }[];
  }

  // Every link, for marking issues that already belong to a goal.
  issueLinks(): { goal: number; repo: string; number: number }[] {
    return this.db.query("select goal, repo, number from goal_issues").all() as { goal: number; repo: string; number: number }[];
  }

  // ── Repositories (name → folder, learned from callers) ─────────────────

  learnRepo(name: string, path: string) {
    this.db.query("insert into repos (name, path) values (?, ?) on conflict(name) do update set path = excluded.path, source = 'learned'").run(name, path);
  }

  // Records a scan (repos.ts): adds new repositories, drops scanned ones that are
  // gone, keeps your ignore choices. A name already taken by another folder is
  // returned as a duplicate (tasks name repositories by folder name).
  syncScanned(found: { name: string; path: string }[]): { added: number; removed: number; duplicates: { name: string; path: string }[] } {
    return this.db.transaction(() => {
      let added = 0;
      const duplicates: { name: string; path: string }[] = [];
      const seen = new Set<string>();
      for (const f of found) {
        const row = this.db.query("select path from repos where name = ?").get(f.name) as { path: string } | null;
        if (!row) {
          this.db.query("insert into repos (name, path, source) values (?, ?, 'scanned')").run(f.name, f.path);
          added++;
        } else if (row.path !== f.path) {
          duplicates.push(f);
          continue;
        }
        seen.add(f.path);
      }
      const scanned = this.db.query("select name, path from repos where source = 'scanned'").all() as { name: string; path: string }[];
      const gone = scanned.filter((r) => !seen.has(r.path));
      for (const r of gone) this.db.query("delete from repos where name = ?").run(r.name);
      return { added, removed: gone.length, duplicates };
    })();
  }

  forgetRepo(name: string) {
    this.db.query("delete from repos where name = ?").run(name);
  }

  setRepoIgnored(name: string, ignored: boolean) {
    const r = this.db.query("update repos set ignored = ? where name = ?").run(ignored ? 1 : 0, name);
    if (r.changes === 0) throw new Error(`unknown repository ${name}`);
  }

  // Its issues stay out of Mission control; agents still know the repository.
  setRepoIssuesIgnored(name: string, ignored: boolean) {
    const r = this.db.query("update repos set issues_ignored = ? where name = ?").run(ignored ? 1 : 0, name);
    if (r.changes === 0) throw new Error(`unknown repository ${name}`);
  }

  // Every known repository; ignored ones only when asked (agents never see them).
  repos(opts: { ignored?: boolean } = {}): { name: string; path: string; source: string; ignored: number; issues_ignored: number }[] {
    return this.db.query(`select name, path, source, ignored, issues_ignored from repos ${opts.ignored ? "" : "where ignored = 0"} order by name`)
      .all() as { name: string; path: string; source: string; ignored: number; issues_ignored: number }[];
  }

  repoPath(name: string | null): string | null {
    if (!name) return null;
    const r = this.db.query("select path from repos where name = ?").get(name) as { path: string } | null;
    return r ? r.path : null;
  }

  // ── Goals ──────────────────────────────────────────────────────────────

  goal(id: number): Goal {
    const g = this.db.query("select * from goals where id = ?").get(id) as Goal | null;
    if (!g) throw new Error(`${Store.gid(id)} doesn't exist`);
    return g;
  }

  listGoals(status?: GoalStatus): Goal[] {
    return status ? this.db.query("select * from goals where status = ? order by id").all(status) as Goal[]
      : this.db.query("select * from goals order by id").all() as Goal[];
  }

  goalEvents(goal: number): Event[] {
    return this.db.query("select * from events where goal = ? order by id").all(goal) as Event[];
  }

  // The goal goal_plan shapes: the caller's own (it coordinates it), or with `ref`
  // a goal not started yet, which any agent may reshape before the user starts it.
  planTarget(session: string, ref?: string): Goal {
    if (!ref) return this.coordinatorGoalFor(session);
    const g = this.goal(Store.parseGoal(ref));
    if (g.status === "proposed" || g.coordinator === session) return g;
    throw new Error(`${Store.gid(g.id)} is ${g.status}: only its coordinator changes it now (message "${Store.gid(g.id)}" to suggest a change)`);
  }

  editGoal(id: number, a: { title?: string; body?: string }) {
    if (a.title != null) this.db.query("update goals set title = ? where id = ?").run(a.title, id);
    if (a.body != null) this.db.query("update goals set body = ? where id = ?").run(a.body, id);
  }

  proposeGoal(caller: Caller, a: { title: string; body: string; tasks: PlanTask[] }): Goal {
    return this.db.transaction(() => {
      const maxGoal = this.db.query("select coalesce(max(id), 0) as m from goals").get() as { m: number };
      const g = this.db.query("insert into goals (id, title, body, status, created) values (?, ?, ?, 'proposed', ?) returning *")
        .get(this.next("goal", maxGoal.m), a.title, a.body, this.now()) as Goal;
      const ids = new Map<string, number>();
      for (const t of a.tasks) {
        const needs = (t.needs ?? []).map((k) => {
          const id = ids.get(k);
          if (id == null) throw new Error(`task '${t.key}' needs '${k}', which isn't listed before it`);
          return id;
        });
        ids.set(t.key, this.addTask(caller, { title: t.title, body: t.body, repo: t.repo, goal: g.id, needs, readonly: t.readonly }).id);
      }
      return g;
    })();
  }

  startGoal(id: number): Goal {
    const g = this.goal(id);
    if (g.status !== "proposed") throw new Error(`${Store.gid(id)} is ${g.status}`);
    this.db.query("update goals set status = 'active' where id = ?").run(id);
    return this.goal(id);
  }

  setGoalSession(id: number, ternSession: string) {
    this.goal(id);
    this.db.query("update goals set tern_session = ? where id = ?").run(ternSession, id);
  }

  // Makes the caller the goal's coordinator, with a task of its own
  // ("Coordinate …") so it can note progress and ask the user like any agent.
  // Other active goals, for a coordinator to coordinate with: "- G3: title (web-app, api)".
  otherGoals(id: number): string {
    return this.listGoals("active").filter((g) => g.id !== id).map((g) => {
      const repos = [...new Set(this.listTasks({ goal: g.id }).filter((t) => t.session !== g.coordinator).map((t) => t.repo).filter(Boolean))];
      return `- ${Store.gid(g.id)}: ${g.title}${repos.length ? ` (${repos.join(", ")})` : ""}`;
    }).join("\n");
  }

  joinGoal(caller: Caller, id: number): Goal {
    const g = this.goal(id);
    if (g.status !== "active") throw new Error(`${Store.gid(id)} is ${g.status}, not active`);
    // Tell the other running goals a new one started, once (not on a rejoin).
    if (g.coordinator == null) for (const o of this.listGoals("active")) {
      if (o.id === id || o.coordinator == null) continue;
      this.addEvent({ task: null, goal: o.id, author: "flightdeck", kind: "status",
        body: `Goal ${Store.gid(id)} started: ${g.title}. If it works in the same repositories, agree with its coordinator (message to "${Store.gid(id)}") on shared things: dev servers and ports, databases and migrations, files you both change.`,
        options: null, recommended: null, to_target: "coordinator" });
    }
    this.db.query("update goals set coordinator = ? where id = ?").run(caller.session, id);
    const own = this.db.query("select id from tasks where goal = ? and session = ? and status = 'doing'").get(id, caller.session);
    if (!own) {
      const now = this.now();
      this.db.query(`insert into tasks (goal, title, body, repo, branch, worktree, status, readonly, session, created, updated)
        values (?, ?, '', ?, ?, ?, 'doing', 1, ?, ?, ?)`)
        .run(id, `Coordinate ${g.title}`, caller.repo, caller.branch, caller.cwd, caller.session, now, now);
    }
    return this.goal(id);
  }

  closeGoal(id: number, status: "done" | "dropped") {
    this.goal(id);
    this.db.query("update goals set status = ?, closed = ? where id = ?").run(status, this.now(), id);
  }

  // Deletes goals closed before `before` (ms) with their tasks, and finished tasks
  // outside goals last changed before it, with everything that refers to them.
  cleanup(before: number): { goals: number; tasks: number } {
    return this.db.transaction(() => {
      const goals = (this.db.query("select id from goals where status in ('done', 'dropped') and coalesce(closed, created) < ?")
        .all(before) as { id: number }[]).map((g) => g.id);
      const tasks = (this.db.query(`select id from tasks where (goal in (select value from json_each(?)))
        or (goal is null and status in ('done', 'dropped', 'failed') and updated < ?)`).all(JSON.stringify(goals), before) as { id: number }[]).map((t) => t.id);
      const t = JSON.stringify(tasks), g = JSON.stringify(goals);
      this.db.query("delete from deps where task in (select value from json_each(?)) or needs in (select value from json_each(?))").run(t, t);
      this.db.query("delete from events where task in (select value from json_each(?)) or goal in (select value from json_each(?))").run(t, g);
      this.db.query("delete from workers where task in (select value from json_each(?)) or goal in (select value from json_each(?))").run(t, g);
      this.db.query("delete from tasks where id in (select value from json_each(?))").run(t);
      this.db.query("delete from goal_issues where goal in (select value from json_each(?))").run(g);
      this.db.query("delete from goals where id in (select value from json_each(?))").run(g);
      return { goals: goals.length, tasks: tasks.length };
    })();
  }

  private finishGoalIfDone(goal: number | null) {
    if (goal == null) return;
    // The coordinator's own task doesn't count: it ends after this summary.
    const open = this.db.query(`select count(*) as n from tasks t join goals g on g.id = t.goal
      where t.goal = ? and t.status not in ('done', 'dropped', 'failed') and (g.coordinator is null or t.session is not g.coordinator)`)
      .get(goal) as { n: number };
    if (open.n > 0) return;
    this.addEvent({ task: null, goal, author: "flightdeck", kind: "status",
      body: "Every task is finished. Verify the work (PRs merged or ready), close finished workers (worker_stop), remove worktrees that are done with (worktree_remove), then finish the goal with goal_complete. Ask the user only for decisions you can't make.",
      options: null, recommended: null, to_target: "coordinator" });
  }

  // Finished worker tasks of a goal, out of all but dropped ones; the coordinator's own task isn't counted.
  progress(goal: number): { done: number; total: number } {
    const r = this.db.query(`select count(*) as total, sum(t.status = 'done') as done from tasks t join goals g on g.id = t.goal
      where t.goal = ? and (g.coordinator is null or t.session is not g.coordinator) and t.status != 'dropped'`).get(goal) as { total: number; done: number | null };
    return { done: r.done ?? 0, total: r.total };
  }

  // A goal's branch in a repository: workers there branch from it and the
  // coordinator merges their work into it, for one PR per repository.
  goalBranch(goal: number, repo: string | null): string | null {
    if (!repo) return null;
    const r = this.db.query("select branch from goal_branches where goal = ? and repo = ?").get(goal, repo) as { branch: string } | null;
    return r?.branch ?? null;
  }

  goalBranches(goal: number): { repo: string; branch: string }[] {
    return this.db.query("select repo, branch from goal_branches where goal = ? order by repo").all(goal) as { repo: string; branch: string }[];
  }

  // Coordinator only; branch null goes back to a PR per task.
  setGoalBranch(session: string, repo: string, branch: string | null): Goal {
    const g = this.coordinatorGoalFor(session);
    if (branch == null) this.db.query("delete from goal_branches where goal = ? and repo = ?").run(g.id, repo);
    else this.db.query("insert into goal_branches (goal, repo, branch) values (?, ?, ?) on conflict(goal, repo) do update set branch = excluded.branch")
      .run(g.id, repo, branch);
    return g;
  }

  coordinatorGoalFor(session: string): Goal {
    const g = this.db.query("select * from goals where coordinator = ? and status = 'active' order by id desc").get(session) as Goal | null;
    if (!g) throw new Error("only a goal's coordinator can do this (goal_join first)");
    return g;
  }

  // ── Questions and messages ─────────────────────────────────────────────

  ask(session: string, a: { ref?: string; question: string; options?: string[]; recommended?: number }): Task {
    const t = this.myTask(session, a.ref);
    if (a.recommended != null && (!a.options || a.recommended < 1 || a.recommended > a.options.length)) {
      throw new Error("recommended is the 1-based number of one of the options");
    }
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "question", body: a.question,
      options: a.options ? JSON.stringify(a.options) : null, recommended: a.recommended ?? null, to_target: "you" });
    return t;
  }

  // Open tasks whose newest question has no answer after it, oldest question first.
  waiting(): { task: Task; question: Event }[] {
    const rows = this.db.query(`select q.* from events q join tasks t on t.id = q.task
      where q.kind = 'question' and t.status not in ('done', 'failed', 'dropped')
      and q.id = (select max(id) from events where task = q.task and kind = 'question')
      and not exists (select 1 from events a where a.task = q.task and a.kind = 'answer' and a.id > q.id)
      order by q.id`).all() as Event[];
    return rows.map((q) => ({ task: this.task(q.task!), question: q }));
  }

  answer(task: number, body: string): Event {
    const t = this.task(task);
    return this.addEvent({ task: t.id, goal: t.goal, author: "you", kind: "answer", body,
      options: null, recommended: null, to_target: `T-${t.id}` });
  }

  message(session: string, a: { ref?: string; to: string; body: string }): Event[] {
    const from = this.myTask(session, a.ref);
    const targets: string[] = [];
    // A goal id ("G3"): that goal's coordinator, so goals sharing a repository can agree on servers, ports, migrations.
    const other = /^@?G-?\d+$/i.test(a.to.trim()) ? Store.parseGoal(a.to.trim().replace(/^@/, "")) : null;
    if (other != null) {
      const g = this.goal(other);
      if (g.status !== "active") throw new Error(`${Store.gid(other)} is ${g.status}, not active`);
      if (other === from.goal) throw new Error("that's your own goal: use @coordinator or @goal");
      return [this.addEvent({ task: from.id, goal: other, author: session, kind: "message",
        body: `**From ${this.tref(from.id)}${from.goal != null ? ` (goal ${Store.gid(from.goal)})` : ""}:** ${a.body}`,
        options: null, recommended: null, to_target: "coordinator" })];
    }
    if (a.to === "@goal" || a.to === "@coordinator") {
      if (from.goal == null) throw new Error(`${a.to} needs your task to belong to a goal`);
      if (a.to === "@coordinator") targets.push("coordinator");
      else for (const t of this.listTasks({ goal: from.goal })) {
        if (t.id !== from.id && t.session && t.status === "doing") targets.push(`T-${t.id}`);
      }
    } else {
      targets.push(`T-${this.task(this.taskId(a.to)).id}`);
    }
    if (targets.length === 0) throw new Error("no other agent on this goal is working right now");
    return targets.map((to) => this.addEvent({ task: from.id, goal: from.goal, author: session, kind: "message",
      body: `**From ${this.tref(from.id)}:** ${a.body}`, options: null, recommended: null, to_target: to }));
  }

  // ── Workers ────────────────────────────────────────────────────────────

  worker(id: number): Worker {
    const w = this.db.query("select * from workers where id = ?").get(id) as Worker | null;
    if (!w) throw new Error(`${Store.wid(id)} doesn't exist`);
    return w;
  }

  // A finished or failed task can get a new worker (follow-up work): it is reopened.
  requestWorker(caller: Caller, task: number, context?: string): Worker {
    const g = this.coordinatorGoalFor(caller.session);
    const t = this.task(task);
    if (t.goal !== g.id) throw new Error(`${this.tref(t.id)} isn't part of ${Store.gid(g.id)}`);
    const isWorker = this.db.query("select 1 from tasks where session = ? and started_by is not null").get(caller.session);
    if (isWorker) throw new Error("workers can't start workers");
    if (!["ready", "done", "failed"].includes(t.status)) throw new Error(`${this.tref(t.id)} is ${t.status}; only ready, done or failed tasks can be started`);
    const busy = this.db.query("select 1 from workers where task = ? and status in ('requested', 'started')").get(t.id);
    if (busy) throw new Error(`${this.tref(t.id)} already has a worker`);
    const active = this.db.query("select count(*) as n from workers where goal = ? and status in ('requested', 'started', 'stopping')").get(g.id) as { n: number };
    if (active.n >= MAX_WORKERS) throw new Error(`${Store.gid(g.id)} already has ${MAX_WORKERS} workers open; close finished ones with worker_stop, or wait for one with inbox`);
    this.db.query("update tasks set started_by = ?, status = 'ready' where id = ?").run(caller.session, t.id);
    return this.db.query("insert into workers (task, goal, requested_by, status, created, context) values (?, ?, ?, 'requested', ?, ?) returning *")
      .get(t.id, g.id, caller.session, this.now(), context ?? null) as Worker;
  }

  workerStarted(id: number, pane: string) {
    this.worker(id);
    this.db.query("update workers set status = 'started', pane = ? where id = ?").run(pane, id);
  }

  workerFailed(id: number, error: string) {
    const w = this.worker(id);
    this.db.query("update workers set status = 'failed' where id = ?").run(id);
    this.addEvent({ task: w.task, goal: w.goal, author: "flightdeck", kind: "status",
      body: `Couldn't start a worker on ${this.tref(w.task)}: ${error}`, options: null, recommended: null, to_target: "coordinator" });
  }

  stopWorker(caller: Caller, task: number): Worker {
    const g = this.coordinatorGoalFor(caller.session);
    const w = this.db.query("select * from workers where task = ? and goal = ? and status in ('requested', 'started') order by id desc")
      .get(task, g.id) as Worker | null;
    if (!w) throw new Error(`${this.tref(task)} has no running worker`);
    this.db.query("update workers set status = 'stopping' where id = ?").run(w.id);
    // A finished task stays finished: stopping just closes its worker.
    const t = this.task(task);
    if (t.status === "doing" || t.status === "ready") this.touch(task, { status: "ready", session: null });
    return this.worker(w.id);
  }

  workerStopped(id: number) {
    this.worker(id);
    this.db.query("update workers set status = 'stopped' where id = ?").run(id);
  }

  pendingWorkers(): { starts: Worker[]; stops: Worker[] } {
    return {
      starts: this.db.query("select * from workers where status = 'requested' order by id").all() as Worker[],
      stops: this.db.query("select * from workers where status = 'stopping' order by id").all() as Worker[],
    };
  }

  // ── Coordinator inbox and deliveries ───────────────────────────────────

  // What the coordinator hasn't seen: workers' dones, messages to @coordinator,
  // goal status, and answers or messages to its own task not yet handed to its
  // pane (a coordinator looping on inbox is mid-turn, so Flightdeck holds pane
  // deliveries; inbox takes them instead, and they count as delivered).
  inbox(session: string): Event[] {
    const g = this.coordinatorGoalFor(session);
    const own = this.db.query("select id from tasks where goal = ? and session = ?").get(g.id, session) as { id: number } | null;
    const rows = this.db.query(`select * from events where (goal = ? and to_target = 'coordinator' and handled is null)
      or (to_target = ? and delivered is null and kind in ('answer', 'message')) order by id`).all(g.id, own ? `T-${own.id}` : "") as Event[];
    const now = this.now();
    for (const e of rows) this.db.query("update events set handled = ?, delivered = coalesce(delivered, ?) where id = ?").run(now, now, e.id);
    return rows;
  }

  // Answers and messages to hand to a task's agent now. An agent-to-agent
  // message waits while its recipient got another one under AGENT_MESSAGE_GAP ago.
  pendingDeliveries(): { event: Event; task: Task }[] {
    const rows = this.db.query(`select e.*, t.id as tid from events e join tasks t on ('T-' || t.id) = e.to_target -- to_target names a task by internal id
      where e.delivered is null and t.session is not null and e.kind in ('answer', 'message') order by e.id`).all() as (Event & { tid: number })[];
    const out: { event: Event; task: Task }[] = [];
    const now = this.now();
    for (const row of rows) {
      if (row.kind === "message") {
        const last = this.db.query("select max(delivered) as at from events where to_target = ? and kind = 'message' and delivered is not null")
          .get(row.to_target) as { at: number | null };
        if (last.at != null && now - last.at < AGENT_MESSAGE_GAP) continue;
      }
      const { tid, ...event } = row;
      out.push({ event, task: this.task(tid) });
    }
    // Inbox items an idle coordinator hasn't read: to its own task's pane.
    const unread = this.db.query(`select e.*, t.id as tid from events e join goals g on g.id = e.goal and g.status = 'active' and g.coordinator is not null
      join tasks t on t.goal = g.id and t.session = g.coordinator and t.status = 'doing'
      where e.to_target = 'coordinator' and e.handled is null and e.delivered is null and e.created < ? order by e.id`)
      .all(now - COORDINATOR_WAKE_MS) as (Event & { tid: number })[];
    for (const row of unread) {
      const { tid, ...event } = row;
      out.push({ event, task: this.task(tid) });
    }
    return out;
  }

  // Delivered to a pane; a coordinator's inbox item then counts as read, so inbox doesn't repeat it.
  markDelivered(event: number) {
    const now = this.now();
    this.db.query("update events set delivered = ?, handled = case when to_target = 'coordinator' then coalesce(handled, ?) else handled end where id = ?")
      .run(now, now, event);
  }
}
