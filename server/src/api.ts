// JSON API for Overseer (window.luau): state for Mission control and the
// sidebar, your answers, goal lifecycle, deliveries to agents, worker starts.
import { Store, type Caller, type TaskStatus } from "./store";

const json = (data: unknown, status = 200) => Response.json(data, { status });
const FINISHED: TaskStatus[] = ["done", "dropped", "failed"];

function field(body: Record<string, unknown>, key: string): string {
  const v = body[key];
  if (typeof v !== "string" || v === "") throw new Error(`missing ${key}`);
  return v;
}

function workerBrief(store: Store, workerId: number) {
  const w = store.worker(workerId);
  const t = store.task(w.task);
  const g = store.goal(w.goal);
  return [
    `You are a worker on goal ${Store.gid(g.id)}: ${g.title}.`,
    `Your task is ${Store.tid(t.id)}: ${t.title}.`, t.body,
    `First call task_start with id "${Store.tid(t.id)}". Use task_note at milestones, ask_user for decisions,`,
    `message @coordinator if you're blocked by other work, and task_done exactly once when finished.`,
    w.context ? `\nFrom your coordinator:\n${w.context}` : "",
  ].filter(Boolean).join("\n");
}

export function coordinatorBrief(store: Store, goal: number) {
  const g = store.goal(goal);
  return [
    `You coordinate goal ${Store.gid(g.id)}: ${g.title}.`, g.body,
    `First call goal_join with "${Store.gid(g.id)}". Then start workers on ready tasks with worker_start,`,
    `wait for results with inbox (it returns after 25 s at most; call it again while workers run), adjust the plan with goal_plan, and send the user a summary with ask_user when every task is finished.`,
    `You own the workers' lifecycle: when a worker's task is done and you've read its result, close it with worker_stop (its worktree stays).`,
    `For follow-up work, start a fresh worker with worker_start, on a new task (goal_plan) or the same finished task, and pass what it needs to know as context.`,
    `When the goal is over, call task_done on your own task.`,
  ].filter(Boolean).join("\n");
}

function state(store: Store) {
  const goals = [...store.listGoals("active"), ...store.listGoals("finished"), ...store.listGoals("proposed")];
  const goalIds = new Set(goals.map((g) => g.id));
  const tasks = store.listTasks({})
    .filter((t) => !FINISHED.includes(t.status) || (t.goal != null && goalIds.has(t.goal)))
    .map((t) => ({ ...t, ref: Store.tid(t.id), repoPath: store.repoPath(t.repo),
      lastNote: store.events(t.id).filter((e) => e.kind === "note").at(-1)?.body ?? null }));
  const waiting = store.waiting().map((w) => ({ task: Store.tid(w.task.id), title: w.task.title, repo: w.task.repo,
    goal: w.task.goal != null ? Store.gid(w.task.goal) : null, question: w.question.body,
    options: w.question.options ? JSON.parse(w.question.options) as string[] : null, recommended: w.question.recommended,
    asked: w.question.created }));
  const workers = store.db.query("select * from workers where status in ('requested', 'started', 'stopping')").all();
  return {
    goals: goals.map((g) => ({ ...g, ref: Store.gid(g.id), progress: store.progress(g.id) })),
    goalSessions: goals.map((g) => g.tern_session).filter((s): s is string => !!s),
    tasks, waiting, workers,
    // The server's clock, so clients can show ages ("3 min ago") without one of their own.
    now: Date.now(),
  };
}

export async function handleApi(store: Store, req: Request, url: URL, resolve: (pane: string) => Caller | null): Promise<Response> {
  const parts = url.pathname.split("/").filter(Boolean).slice(1); // after "api"
  const parsed: unknown = req.method === "POST" ? await req.json().catch(() => ({})) : {};
  const body = (parsed && typeof parsed === "object" ? parsed : {}) as Record<string, unknown>;
  try {
    switch (`${req.method} ${parts[0]}`) {
      case "GET state":
        return json(state(store));
      case "POST panes": {
        // Which omp session runs in each live pane; Overseer delivers by it.
        const panes = Array.isArray(body.panes) ? body.panes.filter((p): p is string => typeof p === "string") : [];
        const map: Record<string, string> = {};
        for (const pane of panes) {
          const caller = resolve(pane);
          if (!caller) continue;
          map[caller.session] = pane;
          if (caller.repo && caller.root) store.learnRepo(caller.repo, caller.root);
        }
        return json(map);
      }
      case "GET backlog": {
        // Every goal and task, newest first, for Mission control's Backlog tab.
        const goals = store.listGoals().reverse().map((g) => ({ ...g, ref: Store.gid(g.id), progress: store.progress(g.id) }));
        const tasks = store.listTasks({}).reverse().map((t) => ({ ...t, ref: Store.tid(t.id) }));
        return json({ goals, tasks, now: Date.now() });
      }
      case "GET thread":
        return json(store.events(Store.parseTask(parts[1] ?? "")));
      case "POST answer":
        return json(store.answer(Store.parseTask(field(body, "task")), field(body, "body")));
      case "POST tasks": {
        const repo = field(body, "repo");
        return json(store.addTask({ session: "you", repo, branch: null, cwd: null },
          { title: field(body, "title"), body: typeof body.body === "string" ? body.body : "", repo }));
      }
      case "POST goals": {
        const goal = Store.parseGoal(parts[1] ?? "");
        if (parts[2] === "start") { store.startGoal(goal); return json({ brief: coordinatorBrief(store, goal) }); }
        if (parts[2] === "session") { store.setGoalSession(goal, field(body, "ternSession")); return json({ ok: true }); }
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
            // existing: the task's branch was made by an earlier worker, so switch to it rather than create it.
            return { id: w.id, task: Store.tid(t.id), title: t.title, repo: t.repo, repoPath: store.repoPath(t.repo), readonly: t.readonly === 1,
              existing: t.branch != null && t.worktree != null, branch: t.branch,
              goal: Store.gid(w.goal), ternSession: store.goal(w.goal).tern_session, brief: workerBrief(store, w.id) };
          }),
          stops: stops.map((w) => ({ id: w.id, pane: w.pane })),
        });
      }
      case "POST workers": {
        const id = Number(parts[1]);
        if (parts[2] === "started") store.workerStarted(id, field(body, "pane"));
        else if (parts[2] === "failed") store.workerFailed(id, field(body, "error"));
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
