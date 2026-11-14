// overseer-server's data and every rule: tasks, goals, dependencies,
// questions, messages, workers and deliveries. SQLite only, no other I/O,
// so the MCP tools and Overseer's HTTP API share the same behaviour.
import { Database } from "bun:sqlite";

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

const SCHEMA = `
create table if not exists goals (
  id integer primary key, title text not null, body text not null default '',
  coordinator text, tern_session text, status text not null, created integer not null);
create table if not exists tasks (
  id integer primary key, goal integer references goals(id), title text not null,
  body text not null default '', repo text, branch text, worktree text, pr text,
  status text not null, readonly integer not null default 0, session text,
  started_by text, created integer not null, updated integer not null);
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
create table if not exists repos (name text primary key, path text not null);
`;

type PlanTask = { key: string; title: string; body?: string; repo: string; needs?: string[]; readonly?: boolean };

export class Store {
  readonly db: Database;

  constructor(path: string, readonly now: () => number = Date.now) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec("pragma journal_mode = wal; pragma foreign_keys = on;");
    this.db.exec(SCHEMA);
    // Added after the first release: databases created before it lack the column.
    const cols = this.db.query("select name from pragma_table_info('workers')").all() as { name: string }[];
    if (!cols.some((c) => c.name === "context")) this.db.exec("alter table workers add column context text");
  }

  static tid(id: number) { return `T-${id}`; }
  static gid(id: number) { return `G-${id}`; }
  static wid(id: number) { return `W-${id}`; }
  static parseTask(ref: string): number {
    const m = /^T-(\d+)$/.exec(ref.trim());
    if (!m) throw new Error(`'${ref}' is not a task id (T-12)`);
    return Number(m[1]);
  }
  static parseGoal(ref: string): number {
    const m = /^G-(\d+)$/.exec(ref.trim());
    if (!m) throw new Error(`'${ref}' is not a goal id (G-3)`);
    return Number(m[1]);
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
    if (!t) throw new Error(`${Store.tid(id)} doesn't exist`);
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
    const t = this.db.query(`insert into tasks (goal, title, body, repo, status, readonly, created, updated)
      values (?, ?, ?, ?, 'todo', ?, ?, ?) returning *`)
      .get(a.goal ?? null, a.title, a.body ?? "", a.repo, a.readonly ? 1 : 0, now, now) as Task;
    for (const need of a.needs ?? []) {
      this.task(need);
      this.db.query("insert into deps (task, needs) values (?, ?)").run(t.id, need);
    }
    this.promote(t.id);
    return this.task(t.id);
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
      return this.db.query(`insert into tasks (title, body, repo, branch, worktree, status, readonly, session, created, updated)
        values (?, ?, ?, ?, ?, 'doing', ?, ?, ?, ?) returning *`)
        .get(a.title, a.body ?? "", caller.repo, caller.branch, caller.cwd, a.readonly ? 1 : 0, caller.session, now, now) as Task;
    }
    const t = this.task(a.id);
    const mine = t.session === caller.session;
    if (!mine && !["todo", "ready"].includes(t.status)) {
      throw new Error(`${Store.tid(t.id)} is ${t.status}${t.session ? " and held by another agent" : ""}`);
    }
    this.touch(t.id, { status: "doing", session: caller.session, branch: caller.branch, worktree: caller.cwd });
    return this.task(t.id);
  }

  myTask(session: string, ref?: string): Task {
    if (ref) {
      const t = this.task(Store.parseTask(ref));
      if (t.session !== session) throw new Error(`${ref} is not yours; call task_start with its id first`);
      return t;
    }
    const doing = this.listTasks({ session, status: "doing" });
    if (doing.length === 0) throw new Error("you have no task in progress; call task_start first");
    if (doing.length > 1) throw new Error(`you have several tasks in progress (${doing.map((t) => Store.tid(t.id)).join(", ")}); pass id`);
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
    this.touch(t.id, { status: a.outcome === "succeeded" ? "done" : "failed" });
    const files = a.files?.length ? `\n\nFiles: ${a.files.map((f) => "`" + f + "`").join(", ")}` : "";
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "done", body: `**${a.outcome}:** ${a.summary}${files}`,
      options: null, recommended: null, to_target: t.goal != null ? "coordinator" : null });
    // The coordinator finishing its own task ends the goal's run.
    const goal = t.goal != null ? this.goal(t.goal) : null;
    if (goal && goal.coordinator === t.session && goal.status === "active") {
      this.db.query("update goals set status = 'finished' where id = ?").run(goal.id);
      return this.task(t.id);
    }
    const dependents = this.db.query("select task from deps where needs = ?").all(t.id) as { task: number }[];
    for (const d of dependents) this.promote(d.task);
    this.finishGoalIfDone(t.goal);
    return this.task(t.id);
  }

  // A coordinator reshaping its plan. Title and body change any time; repo and
  // needs only before the task starts (needs replaces the list).
  editTask(goal: number, task: number, a: { title?: string; body?: string; repo?: string; needs?: number[] }) {
    const t = this.task(task);
    if (t.goal !== goal) throw new Error(`${Store.tid(task)} isn't part of ${Store.gid(goal)}`);
    const started = !["todo", "ready"].includes(t.status);
    if (started && (a.repo != null || a.needs != null)) throw new Error(`${Store.tid(task)} has started; only its title and body can change`);
    const fields: Partial<Task> = {};
    if (a.title != null) fields.title = a.title;
    if (a.body != null) fields.body = a.body;
    if (a.repo != null) fields.repo = a.repo;
    if (Object.keys(fields).length) this.touch(task, fields);
    if (a.needs != null) {
      for (const n of a.needs) if (this.task(n).goal !== goal) throw new Error(`${Store.tid(n)} isn't part of ${Store.gid(goal)}`);
      this.db.query("delete from deps where task = ?").run(task);
      for (const n of a.needs) this.db.query("insert into deps (task, needs) values (?, ?)").run(task, n);
      // Re-derive readiness from the new needs.
      this.touch(task, { status: "todo" });
      this.promote(task);
    }
    return this.task(task);
  }

  dropTask(goal: number, task: number) {
    const t = this.task(task);
    if (t.goal !== goal) throw new Error(`${Store.tid(task)} isn't part of ${Store.gid(goal)}`);
    if (t.status === "doing") throw new Error(`${Store.tid(task)} has a worker; worker_stop it first`);
    this.touch(task, { status: "dropped" });
    this.finishGoalIfDone(goal);
  }

  // ── Repositories (name → folder, learned from callers) ─────────────────

  learnRepo(name: string, path: string) {
    this.db.query("insert into repos (name, path) values (?, ?) on conflict(name) do update set path = excluded.path").run(name, path);
  }

  repos(): { name: string; path: string }[] {
    return this.db.query("select name, path from repos order by name").all() as { name: string; path: string }[];
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

  proposeGoal(caller: Caller, a: { title: string; body: string; tasks: PlanTask[] }): Goal {
    return this.db.transaction(() => {
      const g = this.db.query("insert into goals (title, body, status, created) values (?, ?, 'proposed', ?) returning *")
        .get(a.title, a.body, this.now()) as Goal;
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
  joinGoal(caller: Caller, id: number): Goal {
    const g = this.goal(id);
    if (g.status !== "active") throw new Error(`${Store.gid(id)} is ${g.status}, not active`);
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
    this.db.query("update goals set status = ? where id = ?").run(status, id);
  }

  private finishGoalIfDone(goal: number | null) {
    if (goal == null) return;
    // The coordinator's own task doesn't count: it ends after this summary.
    const open = this.db.query(`select count(*) as n from tasks t join goals g on g.id = t.goal
      where t.goal = ? and t.status not in ('done', 'dropped', 'failed') and t.session is not g.coordinator`)
      .get(goal) as { n: number };
    if (open.n > 0) return;
    this.addEvent({ task: null, goal, author: "overseer", kind: "status",
      body: "Every task is finished. Summarise the outcome for the user with ask_user (what to review, merge order, follow-ups).",
      options: null, recommended: null, to_target: "coordinator" });
  }

  // Finished worker tasks of a goal, out of all but dropped ones; the coordinator's own task isn't counted.
  progress(goal: number): { done: number; total: number } {
    const r = this.db.query(`select count(*) as total, sum(t.status = 'done') as done from tasks t join goals g on g.id = t.goal
      where t.goal = ? and t.session is not g.coordinator and t.status != 'dropped'`).get(goal) as { total: number; done: number | null };
    return { done: r.done ?? 0, total: r.total };
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
      options: null, recommended: null, to_target: Store.tid(t.id) });
  }

  message(session: string, a: { ref?: string; to: string; body: string }): Event[] {
    const from = this.myTask(session, a.ref);
    const targets: string[] = [];
    if (a.to === "@goal" || a.to === "@coordinator") {
      if (from.goal == null) throw new Error(`${a.to} needs your task to belong to a goal`);
      if (a.to === "@coordinator") targets.push("coordinator");
      else for (const t of this.listTasks({ goal: from.goal })) {
        if (t.id !== from.id && t.session && t.status === "doing") targets.push(Store.tid(t.id));
      }
    } else {
      targets.push(Store.tid(this.task(Store.parseTask(a.to)).id));
    }
    if (targets.length === 0) throw new Error("no other agent on this goal is working right now");
    return targets.map((to) => this.addEvent({ task: from.id, goal: from.goal, author: session, kind: "message",
      body: `**From ${Store.tid(from.id)}:** ${a.body}`, options: null, recommended: null, to_target: to }));
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
    if (t.goal !== g.id) throw new Error(`${Store.tid(t.id)} isn't part of ${Store.gid(g.id)}`);
    const isWorker = this.db.query("select 1 from tasks where session = ? and started_by is not null").get(caller.session);
    if (isWorker) throw new Error("workers can't start workers");
    if (!["ready", "done", "failed"].includes(t.status)) throw new Error(`${Store.tid(t.id)} is ${t.status}; only ready, done or failed tasks can be started`);
    const busy = this.db.query("select 1 from workers where task = ? and status in ('requested', 'started')").get(t.id);
    if (busy) throw new Error(`${Store.tid(t.id)} already has a worker`);
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
    this.addEvent({ task: w.task, goal: w.goal, author: "overseer", kind: "status",
      body: `Couldn't start a worker on ${Store.tid(w.task)}: ${error}`, options: null, recommended: null, to_target: "coordinator" });
  }

  stopWorker(caller: Caller, task: number): Worker {
    const g = this.coordinatorGoalFor(caller.session);
    const w = this.db.query("select * from workers where task = ? and goal = ? and status in ('requested', 'started') order by id desc")
      .get(task, g.id) as Worker | null;
    if (!w) throw new Error(`${Store.tid(task)} has no running worker`);
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

  inbox(session: string): Event[] {
    const g = this.coordinatorGoalFor(session);
    const rows = this.db.query("select * from events where goal = ? and to_target = 'coordinator' and handled is null order by id").all(g.id) as Event[];
    const now = this.now();
    for (const e of rows) this.db.query("update events set handled = ? where id = ?").run(now, e.id);
    return rows;
  }

  // Answers and messages to hand to a task's agent now. An agent-to-agent
  // message waits while its recipient got another one under AGENT_MESSAGE_GAP ago.
  pendingDeliveries(): { event: Event; task: Task }[] {
    const rows = this.db.query(`select e.*, t.id as tid from events e join tasks t on ('T-' || t.id) = e.to_target
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
    return out;
  }

  markDelivered(event: number) {
    this.db.query("update events set delivered = ? where id = ?").run(this.now(), event);
  }
}
