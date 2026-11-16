import { describe, expect, test } from "bun:test";
import { Store } from "../src/store";

const me = { session: "s-me", repo: "flightdeck", branch: "main", cwd: "/r/flightdeck" };

describe("schema", () => {
  test("opens an empty store and formats ids", () => {
    const store = new Store(":memory:");
    expect(store.listTasks({})).toEqual([]);
    expect(store.taskId("T-12")).toBe(12);
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }] });
    const loose = store.addTask(me, { title: "l", repo: "x" });
    const inGoal = store.listTasks({ goal: g.id })[0];
    expect([store.tref(inGoal.id), store.tref(loose.id)]).toEqual([`G${g.id}.1`, "T1"]);
    expect([store.taskId(`G${g.id}.1`), store.taskId(`g-${g.id}.1`), store.taskId("T1")]).toEqual([inGoal.id, inGoal.id, loose.id]);
    expect(() => store.taskId("X-1")).toThrow("not a task id");
  });
});

describe("tasks", () => {
  test("start creates a doing task for the caller", () => {
    const store = new Store(":memory:");
    const t = store.startTask(me, { title: "Fix tick" });
    expect(t.status).toBe("doing");
    expect(t.session).toBe("s-me");
    expect(t.repo).toBe("flightdeck");
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
    expect(() => store.myTask("s-me", store.tref(t.id))).toThrow("not yours");
  });

  test("done promotes dependents once every dependency is done", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    const a = store.addTask(me, { title: "a", repo: "x", goal: g.id });
    const b = store.addTask(me, { title: "b", repo: "y", goal: g.id });
    const c = store.addTask(me, { title: "c", repo: "y", goal: g.id, needs: [a.id, b.id] });
    expect(store.task(c.id).status).toBe("todo");
    store.startTask({ ...me, session: "w1" }, { id: a.id });
    store.doneTask("w1", { ref: store.tref(a.id), outcome: "succeeded", summary: "ok" });
    expect(store.task(c.id).status).toBe("todo");
    store.startTask({ ...me, session: "w2" }, { id: b.id });
    store.doneTask("w2", { ref: store.tref(b.id), outcome: "succeeded", summary: "ok" });
    expect(store.task(c.id).status).toBe("ready");
  });

  test("a failed task does not promote dependents", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    const a = store.addTask(me, { title: "a", repo: "x", goal: g.id });
    const c = store.addTask(me, { title: "c", repo: "x", goal: g.id, needs: [a.id] });
    store.startTask({ ...me, session: "w1" }, { id: a.id });
    store.doneTask("w1", { ref: store.tref(a.id), outcome: "failed", summary: "no creds" });
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

describe("goals and conversation", () => {
  const plan = {
    title: "Cross-repo auth", body: "Swap token format",
    tasks: [
      { key: "api", title: "Issue new tokens", repo: "api" },
      { key: "web", title: "Read new tokens", repo: "web", needs: ["api"] },
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

  test("a plan naming an unknown dependency is rejected whole", () => {
    const store = new Store(":memory:");
    expect(() => store.proposeGoal(me, { ...plan, tasks: [{ key: "b", title: "b", repo: "x", needs: ["missing"] }] }))
      .toThrow("isn't listed before it");
    expect(store.listGoals()).toEqual([]);
  });

  test("join makes the caller coordinator; finishing every task tells it", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0]] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    expect(store.goal(g.id).coordinator).toBe("coord");
    const t = store.listTasks({ goal: g.id }).find((x) => x.session !== "coord")!;
    store.startTask({ ...me, session: "w" }, { id: t.id });
    store.doneTask("w", { outcome: "succeeded", summary: "done" });
    expect(store.goalEvents(g.id).map((e) => e.kind)).toContain("status");
  });

  test("a coordinator can ask the user, and its own task doesn't block the goal finishing", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0]] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    const worker = store.listTasks({ goal: g.id }).find((t) => t.session !== "coord")!;
    store.startTask({ ...me, session: "w" }, { id: worker.id });
    store.doneTask("w", { outcome: "succeeded", summary: "done" });
    expect(store.goalEvents(g.id).map((e) => e.kind)).toContain("status");
    store.ask("coord", { question: "Merge order?" });
    expect(store.waiting()[0].task.title).toBe("Coordinate Cross-repo auth");
  });

  test("a coordinator closes a finished worker without reopening its task, and can restart it with context", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0]] });
    store.startGoal(g.id);
    const coord = { ...me, session: "coord" };
    store.joinGoal(coord, g.id);
    const t = store.listTasks({ goal: g.id }).find((x) => x.session !== "coord")!;
    const w = store.requestWorker(coord, t.id);
    store.workerStarted(w.id, "42");
    store.startTask({ ...me, session: "w" }, { id: t.id });
    store.doneTask("w", { outcome: "succeeded", summary: "done" });
    store.stopWorker(coord, t.id);
    expect(store.task(t.id).status).toBe("done");
    store.workerStopped(w.id);
    const again = store.requestWorker(coord, t.id, "Also update the docs.");
    expect(store.task(t.id).status).toBe("ready");
    expect(again.context).toBe("Also update the docs.");
  });

  test("a repository scan adds, keeps ignore choices, reports name clashes and drops vanished repos", () => {
    const store = new Store(":memory:");
    expect(store.syncScanned([{ name: "a", path: "/p/a" }, { name: "b", path: "/p/b" }]).added).toBe(2);
    store.setRepoIgnored("a", true);
    expect(store.repos().map((r) => r.name)).toEqual(["b"]);
    const again = store.syncScanned([{ name: "a", path: "/p/a" }, { name: "a", path: "/q/a" }]);
    expect(again).toMatchObject({ added: 0, removed: 1, duplicates: [{ name: "a", path: "/q/a" }] });
    expect(store.repos({ ignored: true })).toMatchObject([{ name: "a", ignored: 1 }]);
    store.setRepoIssuesIgnored("a", true);
    expect(store.repos({ ignored: true })).toMatchObject([{ name: "a", ignored: 1, issues_ignored: 1 }]);
  });

  test("cleanup deletes closed goals with their tasks and old finished loose tasks, nothing else", () => {
    let clock = 1000;
    const store = new Store(":memory:", () => clock);
    const old = store.proposeGoal(me, { title: "old", body: "", tasks: [{ key: "a", title: "a", repo: "x" }] });
    store.closeGoal(old.id, "done");
    const open = store.proposeGoal(me, { title: "open", body: "", tasks: [{ key: "b", title: "b", repo: "x" }] });
    const loose = store.startTask(me, { title: "loose" });
    store.doneTask("s-me", { outcome: "succeeded", summary: "ok" });
    clock = 5000;
    const recent = store.addTask(me, { title: "recent", repo: "x" });
    expect(store.cleanup(2000)).toEqual({ goals: 1, tasks: 2 });
    expect(store.listGoals().map((g) => g.id)).toEqual([open.id]);
    expect(store.listTasks({}).map((t) => t.title).sort()).toEqual(["b", "recent"]);
    expect(() => store.task(loose.id)).toThrow();
    expect(recent.id).toBeGreaterThan(0);
  });

  test("issues link to a goal once each, and unlink", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    store.linkIssue(g.id, { repo: "o/a", number: 3, title: "Bug" });
    store.linkIssue(g.id, { repo: "o/a", number: 3, title: "Bug, renamed" });
    store.linkIssue(g.id, { repo: "o/b", number: 1 });
    expect(store.goalIssues(g.id)).toMatchObject([{ repo: "o/a", number: 3, title: "Bug, renamed" }, { repo: "o/b", url: "https://github.com/o/b/issues/1" }]);
    store.unlinkIssue(g.id, "o/a", 3);
    expect(store.goalIssues(g.id).length).toBe(1);
  });

  test("a goal can start with no tasks; its coordinator adds, edits and rewires them", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    const a = store.addTask(me, { title: "a", repo: "x", goal: g.id });
    const b = store.addTask(me, { title: "b", repo: "x", goal: g.id });
    expect(store.task(b.id).status).toBe("ready");
    store.editTask(g.id, b.id, { title: "b2", needs: [a.id] });
    expect(store.task(b.id)).toMatchObject({ title: "b2", status: "todo" });
    store.editTask(g.id, b.id, { needs: [] });
    expect(store.task(b.id).status).toBe("ready");
  });

  test("the coordinator finishing its own task marks the goal finished, without another summary request", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0]] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    const worker = store.listTasks({ goal: g.id }).find((t) => t.session !== "coord")!;
    store.startTask({ ...me, session: "w" }, { id: worker.id });
    store.doneTask("w", { outcome: "succeeded", summary: "done" });
    const before = store.goalEvents(g.id).filter((e) => e.kind === "status").length;
    store.doneTask("coord", { outcome: "succeeded", summary: "closed as is" });
    expect(store.goal(g.id).status).toBe("finished");
    expect(store.goalEvents(g.id).filter((e) => e.kind === "status").length).toBe(before);
  });

  test("a note marked answered closes the open question", () => {
    const store = new Store(":memory:");
    store.startTask(me, { title: "a" });
    store.ask("s-me", { question: "Which?" });
    store.note("s-me", { body: "User chose 2 in the pane", answered: true });
    expect(store.waiting()).toEqual([]);
  });

  test("goal progress counts finished worker tasks, not the coordinator's", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }, { key: "b", title: "b", repo: "x" }] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    const a = store.listTasks({ goal: g.id }).find((t) => t.title === "a")!;
    store.startTask({ ...me, session: "w" }, { id: a.id });
    store.doneTask("w", { outcome: "succeeded", summary: "ok" });
    expect(store.progress(g.id)).toEqual({ done: 1, total: 2 });
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
    expect(answer.to_target).toBe(`T-${t.id}`);
  });

  test("a finished task's unanswered question stops waiting", () => {
    const store = new Store(":memory:");
    store.startTask(me, { title: "a" });
    store.ask("s-me", { question: "Ship it?" });
    store.doneTask("s-me", { outcome: "succeeded", summary: "shipped anyway" });
    expect(store.waiting()).toEqual([]);
  });

  test("@goal reaches every other task with an agent", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { ...plan, tasks: [plan.tasks[0], { key: "b", title: "b", repo: "x" }, { key: "c", title: "c", repo: "x" }] });
    const [a, b] = store.listTasks({ goal: g.id });
    store.startTask({ ...me, session: "wa" }, { id: a.id });
    store.startTask({ ...me, session: "wb" }, { id: b.id });
    const sent = store.message("wa", { to: "@goal", body: "heads up" });
    expect(sent.map((e) => e.to_target)).toEqual([`T-${b.id}`]);
  });
});

describe("repositories", () => {
  test("callers teach the store where each repository lives", () => {
    const store = new Store(":memory:");
    store.learnRepo("api", "/Users/j/projects/api");
    store.learnRepo("api", "/Users/j/projects/api");
    expect(store.repoPath("api")).toBe("/Users/j/projects/api");
    expect(store.repoPath("unknown")).toBeNull();
  });
});

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

  test("stopping a worker puts its task back to ready", () => {
    const store = new Store(":memory:");
    const { tasks } = goalWithCoordinator(store);
    const w = store.requestWorker({ ...me, session: "coord" }, tasks[0].id);
    store.workerStarted(w.id, "123");
    store.startTask({ ...me, session: "w" }, { id: tasks[0].id });
    store.stopWorker({ ...me, session: "coord" }, tasks[0].id);
    expect(store.task(tasks[0].id).status).toBe("ready");
    expect(store.pendingWorkers().stops.map((s) => s.id)).toEqual([w.id]);
  });

  test("inbox returns a worker's done once", () => {
    const store = new Store(":memory:");
    const { tasks } = goalWithCoordinator(store);
    store.startTask({ ...me, session: "w" }, { id: tasks[0].id });
    store.doneTask("w", { outcome: "succeeded", summary: "ok" });
    expect(store.inbox("coord").map((e) => e.kind)).toEqual(["done", "status"]);
    expect(store.inbox("coord")).toEqual([]);
  });

  test("a coordinator's inbox takes the user's answers to its own questions, so its pane isn't sent them too", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [] });
    store.startGoal(g.id);
    store.joinGoal({ ...me, session: "coord" }, g.id);
    const own = store.listTasks({ goal: g.id })[0];
    store.ask("coord", { question: "Merge?" });
    store.answer(own.id, "yes");
    expect(store.inbox("coord").map((e) => e.body)).toEqual(["yes"]);
    expect(store.pendingDeliveries()).toEqual([]);
  });

  test("@goal messages reach the other working agents' panes", () => {
    const store = new Store(":memory:");
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }, { key: "b", title: "b", repo: "x" }] });
    const [a, b] = store.listTasks({ goal: g.id });
    store.startTask({ ...me, session: "wa" }, { id: a.id });
    store.startTask({ ...me, session: "wb" }, { id: b.id });
    store.message("wa", { to: "@goal", body: "heads up" });
    expect(store.pendingDeliveries().map((d) => d.task.id)).toEqual([b.id]);
  });

  test("agent messages to one agent are spaced two minutes apart; answers aren't", () => {
    let clock = 0;
    const store = new Store(":memory:", () => clock);
    const g = store.proposeGoal(me, { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }, { key: "b", title: "b", repo: "x" }] });
    const [a, b] = store.listTasks({ goal: g.id });
    store.startTask({ ...me, session: "wa" }, { id: a.id });
    store.startTask({ ...me, session: "wb" }, { id: b.id });
    store.message("wa", { to: store.tref(b.id), body: "one" });
    const firstBatch = store.pendingDeliveries();
    expect(firstBatch.length).toBe(1);
    store.markDelivered(firstBatch[0].event.id);
    clock = 10_000;
    store.message("wa", { to: store.tref(b.id), body: "two" });
    store.answer(b.id, "yes");
    expect(store.pendingDeliveries().map((d) => d.event.kind)).toEqual(["answer"]);
    clock = 130_000;
    expect(store.pendingDeliveries().map((d) => d.event.kind)).toEqual(["message", "answer"]);
  });
});
