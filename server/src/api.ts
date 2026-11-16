// JSON API for Overseer (window.luau): state for Mission control and the
// sidebar, your answers, goal lifecycle, deliveries to agents, worker starts.
import { Store, type Caller, type TaskStatus } from "./store";
import { closeIssue, commentAll, listIssues, parseIssueRef, type Issue } from "./github";

const json = (data: unknown, status = 200) => Response.json(data, { status });
const FINISHED: TaskStatus[] = ["done", "dropped", "failed"];

function field(body: Record<string, unknown>, key: string): string {
  const v = body[key];
  if (typeof v !== "string" || v === "") throw new Error(`missing ${key}`);
  return v;
}

// The user's SSH key lives on a hardware security key that has to be unlocked
// (touch or PIN) about every hour. Agents must ask, never work around it.
const SECURITY_KEY_NOTE = `Git over SSH (push, fetch, pull, clone) uses the user's hardware security key, which needs unlocking about every hour. If an SSH operation fails with "incorrect passphrase", "signing failed", "agent refused operation" or "Permission denied (publickey)", don't work around it: no HTTPS remotes, no new keys, no changing remotes or SSH config. Ask the user with ask_user to unlock their security key, then retry.`;

// How agents treat a goal's linked GitHub issues.
const ISSUES_NOTE = `Overseer comments on linked issues when the goal starts and finishes. Never close issues yourself. A PR that resolves an issue says so in its body with a closing keyword ("Fixes owner/repo#12"), so GitHub closes it on merge. If an issue turns out to be no longer needed, tell the user with ask_user; they decide whether to close it.`;

function issueLines(store: Store, goal: number): string {
  const issues = store.goalIssues(goal);
  if (!issues.length) return "";
  return `Linked GitHub issues (read them with gh issue view):\n${issues.map((i) => `- ${i.repo}#${i.number} ${i.title} ${i.url}`).join("\n")}\n${ISSUES_NOTE}`;
}

// Open issues across known repositories, fetched with gh at most every ISSUES_TTL_MS.
const ISSUES_TTL_MS = 10 * 60_000;
let issueCache: { at: number; issues: Issue[]; errors: string[] } | null = null;
async function issues(store: Store, refresh: boolean) {
  if (refresh || !issueCache || Date.now() - issueCache.at > ISSUES_TTL_MS) {
    const r = await listIssues(store.repos().filter((x) => !x.issues_ignored).map((x) => ({ name: x.name, path: x.path })));
    issueCache = { at: Date.now(), ...r };
  }
  return issueCache;
}

// Links "owner/repo#12" references to a goal, with titles from the issue list when known.
function linkRefs(store: Store, goal: number, refs: unknown) {
  if (!Array.isArray(refs)) return;
  for (const ref of refs) {
    const p = typeof ref === "string" ? parseIssueRef(ref) : null;
    if (!p) throw new Error(`not an issue reference: ${String(ref)} (use owner/repo#12)`);
    const known = issueCache?.issues.find((i) => i.repo === p.repo && i.number === p.number);
    store.linkIssue(goal, { ...p, title: known?.title, url: known?.url });
  }
}

// Tells a goal's linked issues that it finished, with the coordinator's summary.
export function goalFinished(store: Store, goal: number, summary: string) {
  const g = store.goal(goal);
  commentAll(store.goalIssues(goal), `Overseer: goal ${Store.gid(g.id)} "${g.title}" finished.\n\n${summary}`);
}

function workerBrief(store: Store, workerId: number) {
  const w = store.worker(workerId);
  const t = store.task(w.task);
  const g = store.goal(w.goal);
  return [
    `You are a worker on goal ${Store.gid(g.id)}: ${g.title}.`,
    `Your task is ${store.tref(t.id)}: ${t.title}.`, t.body,
    `First call task_start with id "${store.tref(t.id)}". Use task_note at milestones, ask_user for decisions,`,
    `message @coordinator if you're blocked by other work, and task_done exactly once when finished.`,
    issueLines(store, g.id),
    SECURITY_KEY_NOTE,
    w.context ? `\nFrom your coordinator:\n${w.context}` : "",
  ].filter(Boolean).join("\n");
}

export function coordinatorBrief(store: Store, goal: number) {
  const g = store.goal(goal);
  const repos = store.repos();
  return [
    `You coordinate goal ${Store.gid(g.id)}: ${g.title}.`, g.body, issueLines(store, g.id),
    `First call goal_join with "${Store.gid(g.id)}"; it lists any tasks planned so far.`,
    `You own the plan: it may be empty or partial. Read the repositories you need, then break the goal into tasks with goal_plan (add, edit, drop) as you learn more; ask the user with ask_user when the goal is unclear.`,
    repos.length ? `Repositories Overseer knows (use these names as a task's repo):\n${repos.map((r) => `- ${r.name}: ${r.path}`).join("\n")}` : "",
    `Start workers on ready tasks with worker_start,`,
    `wait for results with inbox (it returns after 25 s at most; call it again while workers run), adjust the plan with goal_plan, and send the user a summary with ask_user when every task is finished.`,
    `You own the workers' lifecycle: when a worker's task is done and you've read its result, close it with worker_stop (its worktree stays).`,
    `For follow-up work, start a fresh worker with worker_start, on a new task (goal_plan) or the same finished task, and pass what it needs to know as context.`,
    `When the goal is over, call task_done on your own task.`,
    SECURITY_KEY_NOTE,
  ].filter(Boolean).join("\n");
}

function state(store: Store) {
  const goals = [...store.listGoals("active"), ...store.listGoals("finished"), ...store.listGoals("proposed")];
  const goalIds = new Set(goals.map((g) => g.id));
  const tasks = store.listTasks({})
    .filter((t) => !FINISHED.includes(t.status) || (t.goal != null && goalIds.has(t.goal)))
    .map((t) => ({ ...t, ref: store.tref(t.id), repoPath: store.repoPath(t.repo),
      lastNote: store.events(t.id).filter((e) => e.kind === "note").at(-1)?.body ?? null }));
  const waiting = store.waiting().map((w) => ({ task: store.tref(w.task.id), title: w.task.title, repo: w.task.repo,
    goal: w.task.goal != null ? Store.gid(w.task.goal) : null, question: w.question.body,
    options: w.question.options ? JSON.parse(w.question.options) as string[] : null, recommended: w.question.recommended,
    asked: w.question.created }));
  const workers = store.db.query("select * from workers where status in ('requested', 'started', 'stopping')").all();
  return {
    goals: goals.map((g) => ({ ...g, ref: Store.gid(g.id), progress: store.progress(g.id), issues: store.goalIssues(g.id) })),
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
      case "GET repos":
        return json({ repos: store.repos({ ignored: true }) });
      case "POST repos": {
        // POST /api/repos/<name>/ignore {ignored} (agents don't see it), /ignore-issues {ignored} (Issues tab skips it)
        const name = decodeURIComponent(parts[1] ?? "");
        if (parts[2] === "ignore") store.setRepoIgnored(name, body.ignored === true);
        else if (parts[2] === "ignore-issues") {
          store.setRepoIssuesIgnored(name, body.ignored === true);
          issueCache = null;
        } else break;
        return json({ ok: true });
      }
      case "GET issues": {
        // Open issues of known repositories, each with the goals it's linked to.
        const r = await issues(store, url.searchParams.has("refresh"));
        const links = store.issueLinks();
        return json({ fetched: r.at, now: Date.now(), errors: r.errors, issues: r.issues.map((i) => ({ ...i, body: i.body.slice(0, 2000),
          goals: links.filter((l) => l.repo === i.repo && l.number === i.number).map((l) => Store.gid(l.goal)) })) });
      }
      case "POST issues": {
        // POST /api/issues/close {issue, reason}: only when you ask.
        if (parts[1] !== "close") break;
        const p = parseIssueRef(field(body, "issue"));
        if (!p) throw new Error("not an issue reference");
        const err = await closeIssue(p.repo, p.number, body.reason === "completed" ? "completed" : "not planned");
        if (err) throw new Error(err);
        if (issueCache) issueCache.issues = issueCache.issues.filter((i) => !(i.repo === p.repo && i.number === p.number));
        return json({ ok: true });
      }
      case "GET backlog": {
        // Every goal and task, newest first, for Mission control's Backlog tab.
        const goals = store.listGoals().reverse().map((g) => ({ ...g, ref: Store.gid(g.id), progress: store.progress(g.id), issues: store.goalIssues(g.id) }));
        const tasks = store.listTasks({}).reverse().map((t) => ({ ...t, ref: store.tref(t.id) }));
        // Local midnight: the Backlog's "Done today" starts here.
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        return json({ goals, tasks, now: Date.now(), todayStart: today.getTime() });
      }
      case "GET thread":
        return json(store.events(store.taskId(parts[1] ?? "")));
      case "POST answer":
        return json(store.answer(store.taskId(field(body, "task")), field(body, "body")));
      case "POST tasks": {
        const repo = field(body, "repo");
        return json(store.addTask({ session: "you", repo, branch: null, cwd: null },
          { title: field(body, "title"), body: typeof body.body === "string" ? body.body : "", repo }));
      }
      case "POST goals": {
        // A goal you propose from Mission control: a title and what done looks like; its coordinator plans the tasks.
        if (!parts[1]) {
          const g = store.proposeGoal({ session: "you", repo: null, branch: null, cwd: null },
            { title: field(body, "title"), body: typeof body.body === "string" ? body.body : "", tasks: [] });
          linkRefs(store, g.id, body.issues);
          return json({ ...g, ref: Store.gid(g.id) });
        }
        const goal = Store.parseGoal(parts[1] ?? "");
        if (parts[2] === "start") {
          store.startGoal(goal);
          const g = store.goal(goal);
          commentAll(store.goalIssues(goal), `Overseer: started goal ${Store.gid(goal)} "${g.title}". A coordinator agent is planning and doing the work; this issue will get a summary when it finishes.`);
          return json({ brief: coordinatorBrief(store, goal) });
        }
        if (parts[2] === "issues") { linkRefs(store, goal, [field(body, "issue")]); return json({ issues: store.goalIssues(goal) }); }
        if (parts[2] === "unlink") {
          const p = parseIssueRef(field(body, "issue"));
          if (!p) throw new Error("not an issue reference");
          store.unlinkIssue(goal, p.repo, p.number);
          return json({ issues: store.goalIssues(goal) });
        }
        if (parts[2] === "session") { store.setGoalSession(goal, field(body, "ternSession")); return json({ ok: true }); }
        if (parts[2] === "close") { store.closeGoal(goal, body.status === "dropped" ? "dropped" : "done"); return json({ ok: true }); }
        break;
      }
      case "GET deliveries":
        return json(store.pendingDeliveries().map(({ event, task }) => ({ id: event.id, session: task.session, task: store.tref(task.id),
          text: event.kind === "answer" ? `The user answered on ${store.tref(task.id)}:\n\n${event.body}`
            : `${event.body}\n\n(Reply with the message tool only if it needs one.)` })));
      case "POST deliveries":
        store.markDelivered(Number(parts[1])); return json({ ok: true });
      case "GET workers": {
        const { starts, stops } = store.pendingWorkers();
        return json({
          starts: starts.map((w) => {
            const t = store.task(w.task);
            // existing: the task's branch was made by an earlier worker, so switch to it rather than create it.
            return { id: w.id, task: store.tref(t.id), title: t.title, repo: t.repo, repoPath: store.repoPath(t.repo), readonly: t.readonly === 1,
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
