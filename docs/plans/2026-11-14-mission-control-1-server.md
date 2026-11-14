# Mission control, plan 1 of 4: overseer-server

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local MCP server that stores tasks, goals, events and worker requests in SQLite, gives omp agents the tools from the spec, and gives Overseer an HTTP API.

**Architecture:** One Bun process on `127.0.0.1:8095`. `/mcp` is a stateless MCP endpoint (a fresh `McpServer` per request, Streamable HTTP, JSON responses); the caller is identified by the `X-Tern-Pane` header, resolved to an omp session by `identity.ts`. `/api/*` is a JSON API for Overseer. Everything needs `Authorization: Bearer <token>`. All rules (status changes, dependencies, worker limits, rate limits) live in `store.ts` so both the tools and the API use them.

**Tech Stack:** Bun 1.3 (`bun:sqlite`, `bun test`, `Bun.serve`), `@modelcontextprotocol/sdk` 1.32, `zod` 4.

Spec: `docs/specs/2026-11-14-mission-control-design.md`. Later plans: 2 Overseer integration (server lifecycle, delivery, worker starts, goal sessions), 3 Mission control block and sidebar, 4 migration and Huly removal.

---

## File structure

| File | Responsibility |
|---|---|
| `server/package.json` | Dependencies and scripts |
| `server/src/store.ts` | Schema, every read and write, every rule. No I/O besides SQLite |
| `server/src/identity.ts` | Pane id → `{ session, repo, branch, cwd }`, via `tern process`, `lsof`, `git`; cached |
| `server/src/tools.ts` | Registers the MCP tools on an `McpServer`, calling `store` |
| `server/src/api.ts` | `/api/*` handlers for Overseer |
| `server/src/main.ts` | Config, token, `Bun.serve` routing, auth |
| `server/test/store.test.ts` | Rules |
| `server/test/tools.test.ts` | Tools through a real MCP client (in-memory transport) |
| `server/test/http.test.ts` | Auth, routing, the X-Tern-Pane round trip |

Ids are integers in SQLite and shown as `T-12` / `G-3` / `W-5`. `store.ts` owns that formatting (`tid`, `gid`, `parseTask`).

---

### Task 1: Package and schema

**Files:**
- Create: `server/package.json`, `server/src/store.ts`, `server/test/store.test.ts`

- [ ] **Step 1: Create the package**

```json
{
  "name": "overseer-server",
  "private": true,
  "type": "module",
  "scripts": { "start": "bun src/main.ts", "test": "bun test" },
  "dependencies": { "@modelcontextprotocol/sdk": "1.32.2", "zod": "4.6.7" }
}
```

Run: `cd server && bun install`
Expected: `node_modules/` created, `bun.lock` written. Add `server/node_modules/` to the repo's `.gitignore`.

- [ ] **Step 2: Write the failing test**

```ts
// server/test/store.test.ts
import { describe, expect, test } from "bun:test";
import { Store } from "../src/store";

describe("schema", () => {
  test("opens an empty store and formats ids", () => {
    const store = new Store(":memory:");
    expect(store.listTasks({})).toEqual([]);
    expect(Store.tid(12)).toBe("T-12");
    expect(Store.parseTask("T-12")).toBe(12);
    expect(() => Store.parseTask("X-1")).toThrow("not a task id");
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd server && bun test test/store.test.ts`
Expected: FAIL, `Cannot find module '../src/store'`.

- [ ] **Step 4: Write the schema and id helpers**

```ts
// server/src/store.ts
import { Database } from "bun:sqlite";

export type TaskStatus = "todo" | "ready" | "doing" | "done" | "failed" | "dropped";
export type GoalStatus = "proposed" | "active" | "done" | "dropped";
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
}
export interface Caller { session: string; repo: string | null; branch: string | null; cwd: string | null }

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
  requested_by text not null, status text not null, pane text, created integer not null);
`;

export class Store {
  readonly db: Database;

  constructor(path: string, readonly now: () => number = Date.now) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec("pragma journal_mode = wal; pragma foreign_keys = on;");
    this.db.exec(SCHEMA);
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

  listTasks(filter: { goal?: number; repo?: string; status?: TaskStatus; session?: string }): Task[] {
    const where: string[] = [], args: (string | number)[] = [];
    if (filter.goal != null) { where.push("goal = ?"); args.push(filter.goal); }
    if (filter.repo != null) { where.push("repo = ?"); args.push(filter.repo); }
    if (filter.status != null) { where.push("status = ?"); args.push(filter.status); }
    if (filter.session != null) { where.push("session = ?"); args.push(filter.session); }
    const sql = `select * from tasks ${where.length ? "where " + where.join(" and ") : ""} order by id`;
    return this.db.query(sql).all(...args) as Task[];
  }
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `cd server && bun test test/store.test.ts`
Expected: PASS, 1 test.

- [ ] **Step 6: Commit**

```bash
git add server/package.json server/bun.lock server/src/store.ts server/test/store.test.ts .gitignore
git commit -m "overseer-server: package and schema"
```

---

### Task 2: Tasks: start, add, note, done, dependencies

**Files:**
- Modify: `server/src/store.ts` (add methods to `Store`)
- Modify: `server/test/store.test.ts`

Rules:
- `startTask` without `id` creates a task (`doing`) for the caller; with `id` it claims an existing `todo`/`ready` task (any session) or one already held by the caller.
- `myTask(session, ref?)`: `ref` given → that task, which must be the caller's; else the caller's only `doing` task, error if none or several.
- `doneTask` sets `done`/`failed`, records a `done` event, then promotes dependents: a `todo` task becomes `ready` once every task it needs is `done`.
- `addTask` with no unfinished dependencies is `ready` when it belongs to a goal, `todo` otherwise.

- [ ] **Step 1: Write the failing tests**

```ts
// append to server/test/store.test.ts
const me = { session: "s-me", repo: "overseer", branch: "main", cwd: "/r/overseer" };

describe("tasks", () => {
  test("start creates a doing task for the caller", () => {
    const store = new Store(":memory:");
    const t = store.startTask(me, { title: "Fix tick" });
    expect(t.status).toBe("doing");
    expect(t.session).toBe("s-me");
    expect(t.repo).toBe("overseer");
    expect(store.myTask("s-me").id).toBe(t.id);
  });

  test("myTask needs an id when the caller has several", () => {
    const store = new Store(":memory:");
    store.startTask(me, { title: "a" });
    store.startTask(me, { title: "b" });
    expect(() => store.myTask("s-me")).toThrow("several tasks");
  });

  test("myTask refuses another session's task", () => {
    const store = new Store(":memory:");
    const t = store.startTask({ ...me, session: "s-other" }, { title: "theirs" });
    expect(() => store.myTask("s-me", Store.tid(t.id))).toThrow("not yours");
  });

  test("done promotes dependents once every dependency is done", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    const a = store.addTask(me, { title: "a", repo: "x", goal: g.id });
    const b = store.addTask(me, { title: "b", repo: "y", goal: g.id });
    const c = store.addTask(me, { title: "c", repo: "y", goal: g.id, needs: [a.id, b.id] });
    expect(store.task(c.id).status).toBe("todo");
    store.startTask({ ...me, session: "w1" }, { id: a.id });
    store.doneTask("w1", { ref: Store.tid(a.id), outcome: "succeeded", summary: "ok" });
    expect(store.task(c.id).status).toBe("todo");
    store.startTask({ ...me, session: "w2" }, { id: b.id });
    store.doneTask("w2", { ref: Store.tid(b.id), outcome: "succeeded", summary: "ok" });
    expect(store.task(c.id).status).toBe("ready");
  });

  test("a failed task does not promote dependents", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    const a = store.addTask(me, { title: "a", repo: "x", goal: g.id });
    const c = store.addTask(me, { title: "c", repo: "x", goal: g.id, needs: [a.id] });
    store.startTask({ ...me, session: "w1" }, { id: a.id });
    store.doneTask("w1", { ref: Store.tid(a.id), outcome: "failed", summary: "no creds" });
    expect(store.task(a.id).status).toBe("failed");
    expect(store.task(c.id).status).toBe("todo");
  });

  test("note records an event and sets pr", () => {
    const store = new Store(":memory:");
    const t = store.startTask(me, { title: "a" });
    store.note("s-me", { body: "**Opened PR**", pr: "https://github.com/x/y/pull/3" });
    expect(store.task(t.id).pr).toBe("https://github.com/x/y/pull/3");
    expect(store.events(t.id).map((e) => e.kind)).toEqual(["note"]);
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd server && bun test test/store.test.ts`
Expected: FAIL, `store.startTask is not a function`.

- [ ] **Step 3: Implement**

```ts
// add inside class Store
  task(id: number): Task {
    const t = this.db.query("select * from tasks where id = ?").get(id) as Task | null;
    if (!t) throw new Error(`${Store.tid(id)} doesn't exist`);
    return t;
  }

  events(task: number): Event[] {
    return this.db.query("select * from events where task = ? order by id").all(task) as Event[];
  }

  private touch(id: number, fields: Partial<Task>) {
    const keys = Object.keys(fields);
    const sets = [...keys.map((k) => `${k} = ?`), "updated = ?"].join(", ");
    this.db.query(`update tasks set ${sets} where id = ?`)
      .run(...keys.map((k) => (fields as any)[k]), this.now(), id);
  }

  addEvent(e: Omit<Event, "id" | "created" | "delivered" | "handled">): Event {
    const r = this.db.query(`insert into events (task, goal, author, kind, body, options, recommended, to_target, created)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?) returning *`)
      .get(e.task, e.goal, e.author, e.kind, e.body, e.options, e.recommended, e.to_target, this.now());
    return r as Event;
  }

  addTask(caller: Caller, a: { title: string; body?: string; repo: string; goal?: number; needs?: number[]; readonly?: boolean }): Task {
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

  note(session: string, a: { ref?: string; body: string; pr?: string }): Task {
    const t = this.myTask(session, a.ref);
    if (a.pr) this.touch(t.id, { pr: a.pr });
    else this.touch(t.id, {});
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "note", body: a.body, options: null, recommended: null, to_target: null });
    return this.task(t.id);
  }

  doneTask(session: string, a: { ref?: string; outcome: "succeeded" | "failed"; summary: string; files?: string[] }): Task {
    const t = this.myTask(session, a.ref);
    const status: TaskStatus = a.outcome === "succeeded" ? "done" : "failed";
    this.touch(t.id, { status });
    const files = a.files?.length ? `\n\nFiles: ${a.files.map((f) => "`" + f + "`").join(", ")}` : "";
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "done", body: `**${a.outcome}:** ${a.summary}${files}`,
      options: null, recommended: null, to_target: t.goal != null ? "coordinator" : null });
    const dependents = this.db.query("select task from deps where needs = ?").all(t.id) as { task: number }[];
    for (const d of dependents) this.promote(d.task);
    this.finishGoalIfDone(t.goal);
    return this.task(t.id);
  }

  private finishGoalIfDone(goal: number | null) { /* Task 3 */ }

  proposeGoal(caller: Caller, a: { title: string; body: string; tasks: { key: string; title: string; body?: string; repo: string; needs?: string[]; readonly?: boolean }[] }): Goal {
    throw new Error("Task 3");
  }
```

- [ ] **Step 4: Run the tests**

Run: `cd server && bun test test/store.test.ts`
Expected: the dependency tests FAIL (`Task 3`); the rest PASS. Task 3 makes them pass.

- [ ] **Step 5: Commit**

```bash
git add server/src/store.ts server/test/store.test.ts
git commit -m "overseer-server: tasks, notes, done, dependencies"
```

---

### Task 3: Goals, questions, answers, messages

**Files:**
- Modify: `server/src/store.ts`, `server/test/store.test.ts`

Rules:
- `proposeGoal` creates a `proposed` goal and its tasks (keys map to ids for `needs`).
- `startGoal(id)` → `active` (Overseer, after you press Start); `joinGoal(caller, id)` makes the caller its coordinator.
- A goal whose tasks are all `done`/`dropped`/`failed` gets a `status` event to the coordinator; it stays `active` until you close it (`closeGoal`).
- `ask` records a `question` (options as JSON, `recommended` 1-based). A task is **waiting** while its newest question has no `answer` after it.
- `answer` (you) records an `answer` with `to_target = T-12`, delivered to that task's agent.
- `message` to `T-12` or `@goal` (every other task in the caller's goal with a session) or `@coordinator`.

- [ ] **Step 1: Write the failing tests**

```ts
// append to server/test/store.test.ts
describe("goals and conversation", () => {
  const plan = {
    title: "Cross-repo auth", body: "Swap token format",
    tasks: [
      { key: "api", title: "Issue new tokens", repo: "web-app" },
      { key: "web", title: "Read new tokens", repo: "dashboard", needs: ["api"] },
    ],
  };

  test("propose creates a proposed goal with dependent tasks", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, plan);
    expect(g.status).toBe("proposed");
    const [api, web] = store.listTasks({ goal: g.id });
    expect(api.status).toBe("ready");
    expect(web.status).toBe("todo");
  });

  test("join makes the caller coordinator; finishing every task tells it", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0]] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    expect(store.goal(g.id).coordinator).toBe("coord");
    const [t] = store.listTasks({ goal: g.id });
    store.startTask({ ...me, session: "w" }, { id: t.id });
    store.doneTask("w", { outcome: "succeeded", summary: "done" });
    const kinds = store.goalEvents(g.id).map((e) => e.kind);
    expect(kinds).toContain("status");
  });

  test("a question makes the task waiting until answered", () => {
    const store = new Store(":memory:");
    const t = store.startTask(me, { title: "a" });
    store.ask("s-me", { question: "Which?", options: ["one", "two"], recommended: 1 });
    expect(store.waiting().map((w) => w.task.id)).toEqual([t.id]);
    store.answer(t.id, "2");
    expect(store.waiting()).toEqual([]);
    const answer = store.events(t.id).at(-1)!;
    expect(answer.kind).toBe("answer");
    expect(answer.to_target).toBe(Store.tid(t.id));
  });

  test("@goal reaches every other task with an agent", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0], { key: "b", title: "b", repo: "x" }, { key: "c", title: "c", repo: "x" }] });
    const [a, b, c] = store.listTasks({ goal: g.id });
    store.startTask({ ...me, session: "wa" }, { id: a.id });
    store.startTask({ ...me, session: "wb" }, { id: b.id });
    const sent = store.message("wa", { to: "@goal", body: "heads up" });
    expect(sent.map((e) => e.to_target)).toEqual([Store.tid(b.id)]);
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd server && bun test test/store.test.ts`
Expected: FAIL, `Task 3` / `store.startGoal is not a function`.

- [ ] **Step 3: Implement**

Replace the two Task 3 stubs and add:

```ts
// inside class Store
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

  proposeGoal(caller: Caller, a: { title: string; body: string; tasks: { key: string; title: string; body?: string; repo: string; needs?: string[]; readonly?: boolean }[] }): Goal {
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
    this.db.query("update goals set tern_session = ? where id = ?").run(ternSession, id);
  }

  joinGoal(caller: Caller, id: number): Goal {
    const g = this.goal(id);
    if (g.status !== "active") throw new Error(`${Store.gid(id)} is ${g.status}, not active`);
    this.db.query("update goals set coordinator = ? where id = ?").run(caller.session, id);
    return this.goal(id);
  }

  closeGoal(id: number, status: "done" | "dropped") {
    this.db.query("update goals set status = ? where id = ?").run(status, id);
  }

  private finishGoalIfDone(goal: number | null) {
    if (goal == null) return;
    const open = this.db.query(`select count(*) as n from tasks where goal = ? and status not in ('done', 'dropped', 'failed')`)
      .get(goal) as { n: number };
    if (open.n > 0) return;
    this.addEvent({ task: null, goal, author: "overseer", kind: "status",
      body: "Every task is finished. Summarise the outcome for the user with ask_user (what to review, merge order, follow-ups).",
      options: null, recommended: null, to_target: "coordinator" });
  }

  ask(session: string, a: { ref?: string; question: string; options?: string[]; recommended?: number }): Task {
    const t = this.myTask(session, a.ref);
    if (a.recommended != null && (!a.options || a.recommended < 1 || a.recommended > a.options.length)) {
      throw new Error("recommended is the 1-based number of one of the options");
    }
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "question", body: a.question,
      options: a.options ? JSON.stringify(a.options) : null, recommended: a.recommended ?? null, to_target: "you" });
    return t;
  }

  // Tasks whose newest question has no answer after it, oldest question first.
  waiting(): { task: Task; question: Event }[] {
    const rows = this.db.query(`select q.* from events q where q.kind = 'question'
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
```

- [ ] **Step 4: Run the tests**

Run: `cd server && bun test test/store.test.ts`
Expected: PASS, every test in the file.

- [ ] **Step 5: Commit**

```bash
git add server/src/store.ts server/test/store.test.ts
git commit -m "overseer-server: goals, questions, answers, messages"
```

---

### Task 4: Workers, inbox, deliveries

**Files:**
- Modify: `server/src/store.ts`, `server/test/store.test.ts`

Rules (spec §4, "Sensible launching"):
- `requestWorker(caller, task)`: caller is the goal's coordinator; task is `ready`; no `requested`/`started` worker on it; fewer than `MAX_WORKERS` (4) active in the goal; the caller isn't itself a worker (no task of theirs has `started_by`). Writing tasks always get a worktree (Overseer, plan 2); `readonly` tasks may use the checkout.
- `stopWorker` marks `stopping` (Overseer stops it, then `stopped`) and puts the task back to `ready`.
- `inbox(coordinator)`: unhandled events with `to_target = 'coordinator'` in the caller's goal; marks them handled.
- `pendingDeliveries()`: undelivered events addressed to a task (`to_target` = `T-n`) whose task has a session. An agent-to-agent `message` is held while the same recipient got another agent message less than `AGENT_MESSAGE_GAP` (2 min) ago; answers go at once.

- [ ] **Step 1: Write the failing tests**

```ts
// append to server/test/store.test.ts
describe("workers, inbox, deliveries", () => {
  function goalWithCoordinator(store: Store, n = 1) {
    const tasks = Array.from({ length: n }, (_, i) => ({ key: `t${i}`, title: `t${i}`, repo: "x" }));
    const g = store.proposeGoal(me, { title: "g", body: "", tasks });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    return { g, tasks: store.listTasks({ goal: g.id }) };
  }

  test("a coordinator can request a worker on a ready task, once", () => {
    const store = new Store(":memory:");
    const { tasks } = goalWithCoordinator(store);
    const w = store.requestWorker({ ...me, session: "coord" }, tasks[0].id);
    expect(w.status).toBe("requested");
    expect(() => store.requestWorker({ ...me, session: "coord" }, tasks[0].id)).toThrow("already has a worker");
  });

  test("only the coordinator may request workers", () => {
    const store = new Store(":memory:");
    const { tasks } = goalWithCoordinator(store);
    expect(() => store.requestWorker(me, tasks[0].id)).toThrow("coordinator");
  });

  test("at most four workers per goal", () => {
    const store = new Store(":memory:");
    const { tasks } = goalWithCoordinator(store, 5);
    for (const t of tasks.slice(0, 4)) store.requestWorker({ ...me, session: "coord" }, t.id);
    expect(() => store.requestWorker({ ...me, session: "coord" }, tasks[4].id)).toThrow("4 workers");
  });

  test("inbox returns a worker's done once", () => {
    const store = new Store(":memory:");
    const { tasks } = goalWithCoordinator(store);
    store.startTask({ ...me, session: "w" }, { id: tasks[0].id });
    store.doneTask("w", { outcome: "succeeded", summary: "ok" });
    const first = store.inbox("coord");
    expect(first.map((e) => e.kind)).toEqual(["done", "status"]);
    expect(store.inbox("coord")).toEqual([]);
  });

  test("agent messages to one agent are spaced two minutes apart; answers aren't", () => {
    let clock = 0;
    const store = new Store(":memory:", () => clock);
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }, { key: "b", title: "b", repo: "x" }] });
    const [a, b] = store.listTasks({ goal: g.id });
    store.startTask({ ...me, session: "wa" }, { id: a.id });
    store.startTask({ ...me, session: "wb" }, { id: b.id });
    store.message("wa", { to: Store.tid(b.id), body: "one" });
    const firstBatch = store.pendingDeliveries();
    expect(firstBatch.length).toBe(1);
    store.markDelivered(firstBatch[0].event.id);
    clock = 10_000;
    store.message("wa", { to: Store.tid(b.id), body: "two" });
    store.answer(b.id, "yes");
    expect(store.pendingDeliveries().map((d) => d.event.kind)).toEqual(["answer"]);
    clock = 130_000;
    expect(store.pendingDeliveries().map((d) => d.event.kind)).toEqual(["message", "answer"]);
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd server && bun test test/store.test.ts`
Expected: FAIL, `store.requestWorker is not a function`.

- [ ] **Step 3: Implement**

```ts
// at module level in store.ts
export const MAX_WORKERS = 4;
export const AGENT_MESSAGE_GAP = 120_000;

// inside class Store
  worker(id: number): Worker {
    const w = this.db.query("select * from workers where id = ?").get(id) as Worker | null;
    if (!w) throw new Error(`${Store.wid(id)} doesn't exist`);
    return w;
  }

  private coordinatorGoal(session: string): Goal {
    const g = this.db.query("select * from goals where coordinator = ? and status = 'active' order by id desc").get(session) as Goal | null;
    if (!g) throw new Error("only a goal's coordinator can do this (goal_join first)");
    return g;
  }

  requestWorker(caller: Caller, task: number): Worker {
    const g = this.coordinatorGoal(caller.session);
    const t = this.task(task);
    if (t.goal !== g.id) throw new Error(`${Store.tid(t.id)} isn't part of ${Store.gid(g.id)}`);
    const isWorker = this.db.query("select 1 from tasks where session = ? and started_by is not null").get(caller.session);
    if (isWorker) throw new Error("workers can't start workers");
    if (t.status !== "ready") throw new Error(`${Store.tid(t.id)} is ${t.status}; only ready tasks can be started`);
    const busy = this.db.query("select 1 from workers where task = ? and status in ('requested', 'started')").get(t.id);
    if (busy) throw new Error(`${Store.tid(t.id)} already has a worker`);
    const active = this.db.query("select count(*) as n from workers where goal = ? and status in ('requested', 'started', 'stopping')").get(g.id) as { n: number };
    if (active.n >= MAX_WORKERS) throw new Error(`${Store.gid(g.id)} already has ${MAX_WORKERS} workers; wait for one with inbox`);
    this.db.query("update tasks set started_by = ? where id = ?").run(caller.session, t.id);
    return this.db.query("insert into workers (task, goal, requested_by, status, created) values (?, ?, ?, 'requested', ?) returning *")
      .get(t.id, g.id, caller.session, this.now()) as Worker;
  }

  workerStarted(id: number, pane: string) {
    this.db.query("update workers set status = 'started', pane = ? where id = ?").run(pane, id);
  }

  workerFailed(id: number, error: string) {
    const w = this.worker(id);
    this.db.query("update workers set status = 'failed' where id = ?").run(id);
    this.addEvent({ task: w.task, goal: w.goal, author: "overseer", kind: "status",
      body: `Couldn't start a worker on ${Store.tid(w.task)}: ${error}`, options: null, recommended: null, to_target: "coordinator" });
  }

  stopWorker(caller: Caller, task: number): Worker {
    const g = this.coordinatorGoal(caller.session);
    const w = this.db.query("select * from workers where task = ? and goal = ? and status in ('requested', 'started') order by id desc")
      .get(task, g.id) as Worker | null;
    if (!w) throw new Error(`${Store.tid(task)} has no running worker`);
    this.db.query("update workers set status = 'stopping' where id = ?").run(w.id);
    this.touch(task, { status: "ready", session: null });
    return this.worker(w.id);
  }

  workerStopped(id: number) {
    this.db.query("update workers set status = 'stopped' where id = ?").run(id);
  }

  pendingWorkers(): { starts: Worker[]; stops: Worker[] } {
    return {
      starts: this.db.query("select * from workers where status = 'requested' order by id").all() as Worker[],
      stops: this.db.query("select * from workers where status = 'stopping' order by id").all() as Worker[],
    };
  }

  inbox(session: string): Event[] {
    const g = this.coordinatorGoal(session);
    const rows = this.db.query("select * from events where goal = ? and to_target = 'coordinator' and handled is null order by id").all(g.id) as Event[];
    const now = this.now();
    for (const e of rows) this.db.query("update events set handled = ? where id = ?").run(now, e.id);
    return rows;
  }

  // Events to hand to a task's agent now, with the session to find its pane by.
  pendingDeliveries(): { event: Event; task: Task }[] {
    const rows = this.db.query(`select e.*, t.id as tid from events e join tasks t on ('T-' || t.id) = e.to_target
      where e.delivered is null and t.session is not null and e.kind in ('answer', 'message') order by e.id`).all() as (Event & { tid: number })[];
    const out: { event: Event; task: Task }[] = [];
    const now = this.now();
    for (const row of rows) {
      if (row.kind === "message") {
        const last = this.db.query(`select max(delivered) as at from events where to_target = ? and kind = 'message' and delivered is not null`)
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
```

Note the rate limit: once the first held message is delivered, later ones for the same recipient wait another two minutes. Overseer bundles everything pending for one pane into one prompt (plan 2), so a burst arrives together.

- [ ] **Step 4: Run the tests**

Run: `cd server && bun test test/store.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/src/store.ts server/test/store.test.ts
git commit -m "overseer-server: workers, inbox, rate-limited deliveries"
```

---

### Task 5: Identity

**Files:**
- Create: `server/src/identity.ts`, `server/test/identity.test.ts`

`resolvePane(pane)` returns the omp session running in that Tern pane, its working directory, repository name and branch. It shells out, so the parsing is split into pure functions that are tested on captured output.

- [ ] **Step 1: Write the failing tests**

```ts
// server/test/identity.test.ts
import { expect, test } from "bun:test";
import { sessionFromArgv, sessionFromLsof, repoName } from "../src/identity";

const ID = "01a1ceb5-0463-75df-9c37-f67a82704600";

test("session from --resume and --restore", () => {
  expect(sessionFromArgv(["omp", "--resume", ID])).toBe(ID);
  expect(sessionFromArgv(["/x/omp", "--restore", `/h/.omp/agent/sessions/-p/2026-11-12T07-42-12-067Z_${ID}.jsonl`])).toBe(ID);
  expect(sessionFromArgv(["omp"])).toBeNull();
});

test("session from the open session file", () => {
  const lsof = `p1627\nn/dev/ttys004\nn/Users/j/.omp/agent/sessions/-projects-x/2026-11-12T07-42-12-067Z_${ID}.jsonl\n`;
  expect(sessionFromLsof(lsof)).toBe(ID);
  expect(sessionFromLsof("p1\nn/tmp/other.jsonl\n")).toBeNull();
});

test("repository name from the common git dir", () => {
  expect(repoName("/Users/j/projects/web-app/.git")).toBe("web-app");
  expect(repoName("/Users/j/projects/tern-plugins/overseer/.git")).toBe("overseer");
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd server && bun test test/identity.test.ts`
Expected: FAIL, `Cannot find module '../src/identity'`.

- [ ] **Step 3: Implement**

```ts
// server/src/identity.ts
import { basename, dirname } from "node:path";
import type { Caller } from "./store";

const SESSION_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
const TERN = process.env.TERN_EXE || "/Applications/Tern.app/Contents/MacOS/tern";
const CACHE_MS = 30_000;

export function sessionFromArgv(argv: string[]): string | null {
  const i = argv.findIndex((a) => a === "--resume" || a === "--restore");
  const m = i >= 0 ? SESSION_ID.exec(basename(argv[i + 1] ?? "")) : null;
  return m ? m[0] : null;
}

export function sessionFromLsof(output: string): string | null {
  for (const line of output.split("\n")) {
    if (line.startsWith("n") && line.includes("/.omp/") && line.includes("/sessions/") && line.endsWith(".jsonl")) {
      const m = SESSION_ID.exec(basename(line));
      if (m) return m[0];
    }
  }
  return null;
}

export function repoName(commonGitDir: string): string {
  return basename(dirname(commonGitDir));
}

function run(cmd: string[]): string {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "ignore" });
  return r.stdout.toString();
}

const cache = new Map<string, { at: number; caller: Caller }>();

// The omp session in `pane`, with its folder, repository and branch; null when the pane runs no omp session.
export function resolvePane(pane: string): Caller | null {
  const hit = cache.get(pane);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.caller;
  let info: any;
  try { info = JSON.parse(run([TERN, "process", pane, "--json"])); } catch { return null; }
  const proc = info?.foreground ?? info?.child;
  if (!proc?.pid) return null;
  const session = sessionFromLsof(run(["/usr/sbin/lsof", "-a", "-p", String(proc.pid), "-Fpn"])) ?? sessionFromArgv(proc.argv ?? []);
  if (!session) return null;
  const cwd: string | null = proc.cwd ?? null;
  let repo: string | null = null, branch: string | null = null;
  if (cwd) {
    const common = run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"]).trim();
    if (common) {
      repo = repoName(common);
      branch = run(["git", "-C", cwd, "branch", "--show-current"]).trim() || null;
    }
  }
  const caller = { session, repo, branch, cwd };
  cache.set(pane, { at: Date.now(), caller });
  return caller;
}
```

- [ ] **Step 4: Run the tests**

Run: `cd server && bun test test/identity.test.ts`
Expected: PASS, 3 tests.

- [ ] **Step 5: Check it against this pane**

Run: `cd server && bun -e 'import {resolvePane} from "./src/identity"; console.log(resolvePane(process.env.TERN_PANE!))'`
Expected: an object with this session's id (`echo $PI_SESSION_ID`), `repo: "overseer"`, `branch: "main"`.

- [ ] **Step 6: Commit**

```bash
git add server/src/identity.ts server/test/identity.test.ts
git commit -m "overseer-server: pane to omp session identity"
```

---

### Task 6: MCP tools

**Files:**
- Create: `server/src/tools.ts`, `server/test/tools.test.ts`

Each tool resolves the caller first; a pane that runs no omp session gets a clear error. Tool descriptions carry the rules, since they replace the `huly-tasks` skill.

- [ ] **Step 1: Write the failing test**

```ts
// server/test/tools.test.ts
import { expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Store } from "../src/store";
import { buildServer } from "../src/tools";

async function connect(store: Store, session: string) {
  const caller = { session, repo: "overseer", branch: "main", cwd: "/r" };
  const server = buildServer(store, () => caller);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const r: any = await client.callTool({ name, arguments: args });
    return { text: r.content[0].text as string, error: r.isError === true };
  };
  return { client, call };
}

test("lists every tool from the spec", async () => {
  const { client } = await connect(new Store(":memory:"), "s");
  const names = (await client.listTools()).tools.map((t) => t.name).sort();
  expect(names).toEqual(["ask_user", "goal_join", "goal_plan", "goal_propose", "inbox", "message",
    "task_add", "task_done", "task_list", "task_note", "task_start", "worker_start", "worker_stop"]);
});

test("start, ask, done through the tools", async () => {
  const store = new Store(":memory:");
  const { call } = await connect(store, "s");
  expect((await call("task_start", { title: "Fix tick" })).text).toContain("T-1");
  expect((await call("ask_user", { question: "Which?", options: ["a", "b"], recommended: 1 })).text).toContain("waiting");
  expect(store.waiting().length).toBe(1);
  expect((await call("task_done", { outcome: "succeeded", summary: "fixed" })).text).toContain("done");
});

test("rule errors come back as tool errors, not crashes", async () => {
  const { call } = await connect(new Store(":memory:"), "s");
  const r = await call("task_note", { body: "x" });
  expect(r.error).toBe(true);
  expect(r.text).toContain("task_start first");
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd server && bun test test/tools.test.ts`
Expected: FAIL, `Cannot find module '../src/tools'`.

- [ ] **Step 3: Implement**

```ts
// server/src/tools.ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { Store, type Caller, type Task } from "./store";

type Resolve = () => Caller | null;

const ok = (text: string) => ({ content: [{ type: "text" as const, text }] });
const fail = (text: string) => ({ content: [{ type: "text" as const, text }], isError: true });

function line(t: Task) {
  return `${Store.tid(t.id)} [${t.status}] ${t.title}${t.repo ? ` (${t.repo})` : ""}${t.goal ? ` · ${Store.gid(t.goal)}` : ""}`;
}

export function buildServer(store: Store, resolve: Resolve): McpServer {
  const server = new McpServer({ name: "overseer", version: "1.0.0" });

  // Wraps a handler: resolves the caller, turns thrown rule errors into tool errors.
  function tool<S extends z.ZodRawShape>(name: string, description: string, shape: S,
    fn: (caller: Caller, args: z.infer<z.ZodObject<S>>) => string) {
    server.registerTool(name, { description, inputSchema: shape }, async (args: any) => {
      const caller = resolve();
      if (!caller) return fail("Couldn't tell which omp session is calling: run omp inside a Tern pane.");
      try { return ok(fn(caller, args)); } catch (e) { return fail((e as Error).message); }
    });
  }

  const id = z.string().optional().describe("Task id (T-12); defaults to your only task in progress");

  tool("task_start",
    "Start tracking the work you're doing. Call once at the start of any task that changes something, with a short imperative title. A worker's brief names an existing task: pass its id instead.",
    { title: z.string().optional(), body: z.string().optional().describe("Two or three sentences on the goal, Markdown"),
      id: z.string().optional(), readonly: z.boolean().optional().describe("Research or review only, no changes") },
    (c, a) => line(store.startTask(c, { id: a.id ? Store.parseTask(a.id) : undefined, title: a.title, body: a.body, readonly: a.readonly })) + " — started.");

  tool("task_note",
    "Record a real milestone on your task: a decision, a plan change, a PR opened (pass pr). Not every step; a few lines of Markdown with a bold lead-in.",
    { id, body: z.string(), pr: z.string().url().optional() },
    (c, a) => line(store.note(c.session, { ref: a.id, body: a.body, pr: a.pr })) + " — noted.");

  tool("ask_user",
    "Ask the user for a decision, approval or choice. The only way to reach them. Self-contained question, numbered options, your recommendation as `recommended` (1-based). Ask in your pane too, then wait for the answer.",
    { id, question: z.string(), options: z.array(z.string()).optional(), recommended: z.number().int().optional() },
    (c, a) => line(store.ask(c.session, { ref: a.id, question: a.question, options: a.options, recommended: a.recommended })) + " — waiting for the user.");

  tool("message",
    "Message another agent: `to` is a task id (T-12), `@goal` (every working agent on your goal) or `@coordinator`. Only when your work affects or depends on theirs. Never for decisions the user must make.",
    { id, to: z.string(), body: z.string() },
    (c, a) => `Sent to ${store.message(c.session, { ref: a.id, to: a.to, body: a.body }).map((e) => e.to_target).join(", ")}. Messages from agents arrive at most every 2 minutes.`);

  tool("task_done",
    "Finish your task, exactly once: `succeeded` with the outcome (what changed, how verified), or `failed` with what's left. List files changed.",
    { id, outcome: z.enum(["succeeded", "failed"]), summary: z.string(), files: z.array(z.string()).optional() },
    (c, a) => line(store.doneTask(c.session, { ref: a.id, outcome: a.outcome, summary: a.summary, files: a.files })) + " — finished.");

  tool("task_add",
    "Add a task for later, in any repository: a follow-up worth doing. Optionally part of a goal (G-3) and depending on other tasks.",
    { title: z.string(), body: z.string().optional(), repo: z.string(), goal: z.string().optional(),
      needs: z.array(z.string()).optional(), readonly: z.boolean().optional() },
    (c, a) => line(store.addTask(c, { title: a.title, body: a.body, repo: a.repo,
      goal: a.goal ? Store.parseGoal(a.goal) : undefined, needs: (a.needs ?? []).map(Store.parseTask), readonly: a.readonly })) + " — added.");

  tool("task_list",
    "List tasks: by goal (G-3), repository, status, or mine.",
    { goal: z.string().optional(), repo: z.string().optional(),
      status: z.enum(["todo", "ready", "doing", "done", "failed", "dropped"]).optional(), mine: z.boolean().optional() },
    (c, a) => store.listTasks({ goal: a.goal ? Store.parseGoal(a.goal) : undefined, repo: a.repo, status: a.status,
      session: a.mine ? c.session : undefined }).map(line).join("\n") || "No tasks.");

  const planTask = z.object({ key: z.string(), title: z.string(), body: z.string().optional(), repo: z.string(),
    needs: z.array(z.string()).optional().describe("Keys of tasks listed before this one"), readonly: z.boolean().optional() });

  tool("goal_propose",
    "Propose a goal that spans tasks, usually across repositories, with dependencies. The user sees it in Mission control and starts it; a coordinator then runs it in its own session. Don't start the work yourself.",
    { title: z.string(), body: z.string(), tasks: z.array(planTask).min(1) },
    (c, a) => `${Store.gid(store.proposeGoal(c, a).id)} proposed; the user will start it.`);

  tool("goal_join",
    "Coordinator only: your first call. Makes you the coordinator of the goal named in your brief.",
    { goal: z.string() },
    (c, a) => {
      const g = store.joinGoal(c, Store.parseGoal(a.goal));
      return `You coordinate ${Store.gid(g.id)}: ${g.title}.\n` + store.listTasks({ goal: g.id }).map(line).join("\n");
    });

  tool("goal_plan",
    "Coordinator only: add tasks to your goal (needs may name existing task ids or keys added in this call), or drop tasks.",
    { add: z.array(planTask).optional(), drop: z.array(z.string()).optional() },
    (c, a) => {
      const g = store.coordinatorGoalFor(c.session);
      const keys = new Map<string, number>();
      for (const t of a.add ?? []) {
        const needs = (t.needs ?? []).map((n) => keys.get(n) ?? Store.parseTask(n));
        keys.set(t.key, store.addTask(c, { title: t.title, body: t.body, repo: t.repo, goal: g.id, needs, readonly: t.readonly }).id);
      }
      for (const ref of a.drop ?? []) store.dropTask(g.id, Store.parseTask(ref));
      return store.listTasks({ goal: g.id }).map(line).join("\n");
    });

  tool("worker_start",
    "Coordinator only: start an omp worker on a ready task. Overseer gives it its own worktree (read-only tasks may use the checkout) and opens it as a tab in the goal's session. At most 4 workers per goal.",
    { task: z.string() },
    (c, a) => `${Store.wid(store.requestWorker(c, Store.parseTask(a.task)).id)} requested for ${a.task}; its done arrives in your inbox.`);

  tool("worker_stop",
    "Coordinator only: stop a task's worker; the task goes back to ready.",
    { task: z.string() },
    (c, a) => `${Store.wid(store.stopWorker(c, Store.parseTask(a.task)).id)} stopping; ${a.task} is ready again.`);

  server.registerTool("inbox", {
    description: "Coordinator only: wait (up to timeout_s, default 600) for workers' done messages, messages to @coordinator and goal status. Returns them once.",
    inputSchema: { timeout_s: z.number().int().min(1).max(1800).optional() },
  }, async (args: any) => {
    const caller = resolve();
    if (!caller) return fail("Couldn't tell which omp session is calling.");
    const until = Date.now() + (args.timeout_s ?? 600) * 1000;
    try {
      for (;;) {
        const events = store.inbox(caller.session);
        if (events.length) return ok(events.map((e) => `${e.task ? Store.tid(e.task) : "goal"} · ${e.kind}: ${e.body}`).join("\n\n"));
        if (Date.now() >= until) return ok("Nothing yet.");
        await Bun.sleep(1000);
      }
    } catch (e) { return fail((e as Error).message); }
  });

  return server;
}
```

Add to `Store` (used by `goal_plan`):

```ts
  coordinatorGoalFor(session: string): Goal { return this.coordinatorGoal(session); }

  dropTask(goal: number, task: number) {
    const t = this.task(task);
    if (t.goal !== goal) throw new Error(`${Store.tid(task)} isn't part of ${Store.gid(goal)}`);
    if (t.status === "doing") throw new Error(`${Store.tid(task)} has a worker; worker_stop it first`);
    this.touch(task, { status: "dropped" });
    this.finishGoalIfDone(goal);
  }
```

- [ ] **Step 4: Run the tests**

Run: `cd server && bun test`
Expected: PASS, every file.

- [ ] **Step 5: Commit**

```bash
git add server/src/tools.ts server/src/store.ts server/test/tools.test.ts
git commit -m "overseer-server: MCP tools"
```

---

### Task 7: HTTP: auth, /mcp, /api

**Files:**
- Create: `server/src/api.ts`, `server/src/main.ts`, `server/test/http.test.ts`

API for Overseer (all JSON, all behind the token):

| Route | Does |
|---|---|
| `GET /health` | `{ ok: true }` (no token needed) |
| `GET /api/state` | `{ goals, tasks, waiting, workers }`: active and proposed goals, open tasks with their latest note, questions waiting on you, active workers |
| `GET /api/thread/:task` | Every event on a task |
| `POST /api/answer` | `{ task: "T-12", body }` |
| `POST /api/tasks` | `{ title, body?, repo }`: a task you add |
| `POST /api/goals/:goal/start` | `proposed` → `active`; returns the coordinator's brief |
| `POST /api/goals/:goal/session` | `{ ternSession }` |
| `POST /api/goals/:goal/close` | `{ status: "done" | "dropped" }` |
| `GET /api/deliveries` | `[{ id, session, text }]` |
| `POST /api/deliveries/:id/done` | marks delivered |
| `GET /api/workers` | `{ starts: [{ id, task, title, repo, readonly, goal, ternSession, brief }], stops: [{ id, pane }] }` |
| `POST /api/workers/:id/started` · `/failed` · `/stopped` | `{ pane }` · `{ error }` · `{}` |

- [ ] **Step 1: Write the failing test**

```ts
// server/test/http.test.ts
import { afterAll, beforeAll, expect, test } from "bun:test";
import { startServer } from "../src/main";

let stop: () => void;
const base = "http://127.0.0.1:18095";
const token = "test-token";

beforeAll(() => {
  stop = startServer({ port: 18095, dbPath: ":memory:", token,
    resolve: (pane) => (pane === "42" ? { session: "s42", repo: "overseer", branch: "main", cwd: "/r" } : null) });
});
afterAll(() => stop());

const auth = { Authorization: `Bearer ${token}` };

test("health needs no token; the API does", async () => {
  expect((await fetch(`${base}/health`)).status).toBe(200);
  expect((await fetch(`${base}/api/state`)).status).toBe(401);
  expect((await fetch(`${base}/api/state`, { headers: auth })).status).toBe(200);
});

test("a tool call identifies its caller by X-Tern-Pane", async () => {
  const r = await fetch(`${base}/mcp`, {
    method: "POST",
    headers: { ...auth, "X-Tern-Pane": "42", "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "task_start", arguments: { title: "Probe" } } }),
  });
  const body: any = await r.json();
  expect(body.result.content[0].text).toContain("T-1");
  const state: any = await (await fetch(`${base}/api/state`, { headers: auth })).json();
  expect(state.tasks[0].session).toBe("s42");
});

test("answers become deliveries for the task's session", async () => {
  await fetch(`${base}/api/answer`, { method: "POST", headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ task: "T-1", body: "go ahead" }) });
  const deliveries: any[] = await (await fetch(`${base}/api/deliveries`, { headers: auth })).json();
  expect(deliveries[0].session).toBe("s42");
  expect(deliveries[0].text).toContain("go ahead");
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd server && bun test test/http.test.ts`
Expected: FAIL, `Cannot find module '../src/main'`.

- [ ] **Step 3: Implement the API**

```ts
// server/src/api.ts
import { Store } from "./store";

const json = (data: unknown, status = 200) => Response.json(data, { status });

function workerBrief(store: Store, workerId: number) {
  const w = store.worker(workerId);
  const t = store.task(w.task);
  const g = store.goal(w.goal);
  return [
    `You are a worker on goal ${Store.gid(g.id)}: ${g.title}.`,
    `Your task is ${Store.tid(t.id)}: ${t.title}.`, t.body,
    `First call task_start with id "${Store.tid(t.id)}". Use task_note at milestones, ask_user for decisions,`,
    `message @coordinator if you're blocked by other work, and task_done exactly once when finished.`,
  ].filter(Boolean).join("\n");
}

export function coordinatorBrief(store: Store, goal: number) {
  const g = store.goal(goal);
  return [
    `You coordinate goal ${Store.gid(g.id)}: ${g.title}.`, g.body,
    `First call goal_join with "${Store.gid(g.id)}". Then start workers on ready tasks with worker_start,`,
    `wait for results with inbox, adjust the plan with goal_plan, and send the user a summary with ask_user when every task is finished.`,
  ].filter(Boolean).join("\n");
}

export async function handleApi(store: Store, req: Request, url: URL): Promise<Response> {
  const parts = url.pathname.split("/").filter(Boolean).slice(1); // after "api"
  const body = req.method === "POST" ? ((await req.json().catch(() => ({}))) as any) : {};
  try {
    switch (`${req.method} ${parts[0]}`) {
      case "GET state": {
        const goals = [...store.listGoals("active"), ...store.listGoals("proposed")];
        const tasks = store.listTasks({}).filter((t) => !["done", "dropped", "failed"].includes(t.status)
          || (t.goal != null && goals.some((g) => g.id === t.goal)))
          .map((t) => ({ ...t, ref: Store.tid(t.id), lastNote: store.events(t.id).filter((e) => e.kind === "note").at(-1)?.body ?? null }));
        const waiting = store.waiting().map((w) => ({ task: Store.tid(w.task.id), title: w.task.title, repo: w.task.repo,
          question: w.question.body, options: w.question.options ? JSON.parse(w.question.options) : null, recommended: w.question.recommended }));
        const workers = store.db.query("select * from workers where status in ('requested', 'started', 'stopping')").all();
        return json({ goals: goals.map((g) => ({ ...g, ref: Store.gid(g.id) })), tasks, waiting, workers });
      }
      case "GET thread":
        return json(store.events(Store.parseTask(parts[1])));
      case "POST answer":
        return json(store.answer(Store.parseTask(body.task), String(body.body)));
      case "POST tasks":
        return json(store.addTask({ session: "you", repo: body.repo, branch: null, cwd: null }, { title: body.title, body: body.body, repo: body.repo }));
      case "POST goals": {
        const goal = Store.parseGoal(parts[1]);
        if (parts[2] === "start") { store.startGoal(goal); return json({ brief: coordinatorBrief(store, goal) }); }
        if (parts[2] === "session") { store.setGoalSession(goal, String(body.ternSession)); return json({ ok: true }); }
        if (parts[2] === "close") { store.closeGoal(goal, body.status === "dropped" ? "dropped" : "done"); return json({ ok: true }); }
        break;
      }
      case "GET deliveries":
        return json(store.pendingDeliveries().map(({ event, task }) => ({ id: event.id, session: task.session, task: Store.tid(task.id),
          text: event.kind === "answer" ? `The user answered on ${Store.tid(task.id)}:\n\n${event.body}`
            : `${event.body}\n\n(Reply with the message tool only if it needs one.)` })));
      case "POST deliveries":
        store.markDelivered(Number(parts[1])); return json({ ok: true });
      case "GET workers": {
        const { starts, stops } = store.pendingWorkers();
        return json({
          starts: starts.map((w) => {
            const t = store.task(w.task);
            return { id: w.id, task: Store.tid(t.id), title: t.title, repo: t.repo, readonly: t.readonly === 1,
              goal: Store.gid(w.goal), ternSession: store.goal(w.goal).tern_session, brief: workerBrief(store, w.id) };
          }),
          stops: stops.map((w) => ({ id: w.id, pane: w.pane })),
        });
      }
      case "POST workers": {
        const id = Number(parts[1]);
        if (parts[2] === "started") store.workerStarted(id, String(body.pane));
        else if (parts[2] === "failed") store.workerFailed(id, String(body.error));
        else if (parts[2] === "stopped") store.workerStopped(id);
        else break;
        return json({ ok: true });
      }
    }
    return json({ error: "not found" }, 404);
  } catch (e) {
    return json({ error: (e as Error).message }, 400);
  }
}
```

- [ ] **Step 4: Implement main**

```ts
// server/src/main.ts
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Store, type Caller } from "./store";
import { buildServer } from "./tools";
import { handleApi } from "./api";
import { resolvePane } from "./identity";

export function startServer(opts: { port: number; dbPath: string; token: string; resolve?: (pane: string) => Caller | null }) {
  const store = new Store(opts.dbPath);
  const resolve = opts.resolve ?? resolvePane;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: opts.port,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/health") return Response.json({ ok: true });
      if (req.headers.get("authorization") !== `Bearer ${opts.token}`) return new Response("unauthorized", { status: 401 });
      if (url.pathname === "/mcp") {
        const pane = req.headers.get("x-tern-pane") ?? "";
        // Stateless: a fresh server and transport per request.
        const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
        await buildServer(store, () => (pane ? resolve(pane) : null)).connect(transport);
        return transport.handleRequest(req);
      }
      if (url.pathname.startsWith("/api/")) return handleApi(store, req, url);
      return new Response("not found", { status: 404 });
    },
  });
  return () => server.stop(true);
}

// `bun src/main.ts <data dir>`: Overseer passes its plugin data directory.
if (import.meta.main) {
  const dir = process.argv[2] ?? join(process.env.HOME!, ".local/share/overseer");
  mkdirSync(dir, { recursive: true });
  const tokenPath = join(dir, "token");
  if (!existsSync(tokenPath)) writeFileSync(tokenPath, crypto.randomUUID().replaceAll("-", ""), { mode: 0o600 });
  const token = readFileSync(tokenPath, "utf8").trim();
  startServer({ port: Number(process.env.OVERSEER_PORT ?? 8095), dbPath: join(dir, "overseer.db"), token });
  console.log(`overseer-server on 127.0.0.1:${process.env.OVERSEER_PORT ?? 8095}, data in ${dir}`);
}
```

- [ ] **Step 5: Run every test**

Run: `cd server && bun test`
Expected: PASS, every file.

- [ ] **Step 6: Commit**

```bash
git add server/src/api.ts server/src/main.ts server/test/http.test.ts
git commit -m "overseer-server: HTTP API and MCP endpoint"
```

---

### Task 8: End to end with a real omp agent

**Files:** none changed; a throwaway omp config.

- [ ] **Step 1: Start the server on a test port with a scratch data dir**

Run: `cd server && OVERSEER_PORT=18096 bun src/main.ts /tmp/ov-e2e & sleep 1; curl -s 127.0.0.1:18096/health`
Expected: `{"ok":true}`

- [ ] **Step 2: Point a throwaway project at it**

```bash
mkdir -p /tmp/ov-e2e/proj/.omp && cd /tmp/ov-e2e/proj && git init -q
cat > .omp/mcp.json <<EOF
{"mcpServers":{"overseer":{"type":"http","url":"http://127.0.0.1:18096/mcp",
  "headers":{"X-Tern-Pane":"\${TERN_PANE}","Authorization":"Bearer $(cat /tmp/ov-e2e/token)"}}}}
EOF
```

- [ ] **Step 3: Run an agent through start, ask, done**

Run: `cd /tmp/ov-e2e/proj && omp -p "Use the overseer tools: task_start 'E2E probe', ask_user 'Ship it?' with options yes/no recommending 1, then task_done succeeded 'probe done'. Print the tool outputs."`
Expected: outputs with `T-1 … started`, `waiting for the user`, `finished`.

- [ ] **Step 4: Check the state Overseer will read**

Run: `curl -s -H "Authorization: Bearer $(cat /tmp/ov-e2e/token)" 127.0.0.1:18096/api/state | jq '.tasks, .waiting'`
Expected: T-1 with this pane's omp session in `session`, `repo: "proj"`; the question listed in `waiting`.

- [ ] **Step 5: Clean up**

Run: `pkill -f 'bun src/main.ts /tmp/ov-e2e'; rm -rf /tmp/ov-e2e`

---

## Self-review

- **Spec coverage:** §1 server, token, port: Tasks 1, 7. §2 identity: Task 5. §3 data: Tasks 1–4. §4 tools and launch rules: Tasks 2–4, 6 (worktree creation itself is Overseer's: plan 2). §5 delivery queue and rate limit: Task 4, API in Task 7; the sending is plan 2. §6 Mission control, §7 goal sessions, §8 cutover: plans 2–4. Verification 1 (server, health, token, tools): Tasks 6–8.
- **Deviations from the spec, recorded:** questions are `ask_user` events addressed `you`; coordinators are reached as `@coordinator` (a `to_target` of `coordinator`), which the spec's `message` didn't name; `goal_plan` adds and drops but doesn't edit (drop and re-add instead).
- **Names used across tasks:** `Store.tid/gid/wid/parseTask/parseGoal`, `startTask`, `myTask`, `note`, `doneTask`, `addTask`, `proposeGoal`, `startGoal`, `joinGoal`, `setGoalSession`, `closeGoal`, `ask`, `waiting`, `answer`, `message`, `requestWorker`, `workerStarted/Failed/Stopped`, `stopWorker`, `pendingWorkers`, `inbox`, `pendingDeliveries`, `markDelivered`, `coordinatorGoalFor`, `dropTask`, `buildServer`, `startServer`, `handleApi`, `resolvePane`.
