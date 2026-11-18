// The MCP tools agents see. Each resolves its caller (the omp session in the
// calling pane) and turns a broken rule into a tool error the agent can read.
// Descriptions carry the rules, so agents need no separate skill.
import { goalFinished } from "./api";
import { parseIssueRef } from "./github";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { Store, type Caller, type Task } from "./store";

type Resolve = () => Caller | null;

const ok = (text: string) => ({ content: [{ type: "text" as const, text }] });
const fail = (text: string) => ({ content: [{ type: "text" as const, text }], isError: true });
const NO_CALLER = "Couldn't tell which omp session is calling: run omp inside a Tern pane.";


export function buildServer(store: Store, resolve: Resolve): McpServer {
  function line(t: Task) {
    const deps = store.dependencyText(t.id);
    return `${store.tref(t.id)} [${t.status}] ${t.title}${t.repo ? ` (${t.repo})` : ""}${t.goal ? ` · ${Store.gid(t.goal)}` : ""}${deps ? ` · ${deps}` : ""}`;
  }

  const server = new McpServer({ name: "flightdeck", version: "1.0.0" });

  function tool<S extends z.ZodRawShape>(name: string, description: string, shape: S,
    fn: (caller: Caller, args: z.infer<z.ZodObject<S>>) => string) {
    // The SDK validates arguments against `shape` before calling, so the cast only names that type.
    server.registerTool(name, { description, inputSchema: shape }, async (args: unknown) => {
      const caller = resolve();
      if (!caller) return fail(NO_CALLER);
      if (caller.repo && caller.root) store.learnRepo(caller.repo, caller.root);
      try { return ok(fn(caller, args as z.infer<z.ZodObject<S>>)); } catch (e) { return fail((e as Error).message); }
    });
  }

  const id = z.string().optional().describe("Task id: G3.2 (a goal's task) or T7 (outside goals); defaults to your only task in progress");

  tool("task_start",
    "Start tracking the work you're doing. Call once at the start of any task that changes something, with a short imperative title. A worker's brief names an existing task: pass its id instead.",
    { title: z.string().optional(), body: z.string().optional().describe("Two or three sentences on the goal, Markdown"),
      id: z.string().optional(), readonly: z.boolean().optional().describe("Research or review only, no changes") },
    (c, a) => line(store.startTask(c, { id: a.id ? store.taskId(a.id) : undefined, title: a.title, body: a.body, readonly: a.readonly })) + " — started.");

  tool("task_note",
    "Record a real milestone on your task: a decision, a plan change, a PR opened (pass pr). Not every step; a few lines of Markdown with a bold lead-in.",
    { id, body: z.string(), pr: z.string().url().optional(),
      answered: z.boolean().optional().describe("True when this note records the user's answer to your open question, given in your pane") },
    (c, a) => line(store.note(c.session, { ref: a.id, body: a.body, pr: a.pr, answered: a.answered })) + " — noted.");

  tool("ask_user",
    "Ask the user for a decision, approval or choice. The only way to reach them. Self-contained question, numbered options, your recommendation as `recommended` (1-based). Ask in your pane too, then wait for the answer. If the user answers in your pane, record it with task_note answered: true.",
    { id, question: z.string(), options: z.array(z.string()).optional(), recommended: z.number().int().optional() },
    (c, a) => line(store.ask(c.session, { ref: a.id, question: a.question, options: a.options, recommended: a.recommended })) + " — waiting for the user.");

  tool("message",
    "Message another agent: `to` is a task id (G3.2, or T7), `@goal` (every working agent on your goal), `@coordinator`, or another goal (G4: its coordinator). Only when your work affects or depends on theirs. Never for decisions the user must make.",
    { id, to: z.string(), body: z.string() },
    (c, a) => `Sent to ${store.message(c.session, { ref: a.id, to: a.to, body: a.body }).map((e) => e.to_target).join(", ")}. Messages from agents arrive at most every 2 minutes.`);

  tool("task_done",
    "Finish your task, exactly once: `succeeded` with the outcome (what changed, how verified), or `failed` with what's left. List files changed.",
    { id, outcome: z.enum(["succeeded", "failed"]), summary: z.string(), files: z.array(z.string()).optional() },
    (c, a) => {
      const t = store.doneTask(c.session, { ref: a.id, outcome: a.outcome, summary: a.summary, files: a.files });
      return line(t) + " — finished.";
    });

  tool("task_add",
    "Add a task for later, in any repository: a follow-up worth doing. Optionally part of a goal (G3) and depending on other tasks.",
    { title: z.string(), body: z.string().optional(), repo: z.string(), goal: z.string().optional(),
      needs: z.array(z.string()).optional(), readonly: z.boolean().optional() },
    (c, a) => line(store.addTask(c, { title: a.title, body: a.body, repo: a.repo,
      goal: a.goal ? Store.parseGoal(a.goal) : undefined, needs: (a.needs ?? []).map((r) => store.taskId(r)), readonly: a.readonly })) + " — added.");

  tool("task_list",
    "List tasks: by goal (G3), repository, status, or mine.",
    { goal: z.string().optional(), repo: z.string().optional(),
      status: z.enum(["todo", "ready", "doing", "done", "failed", "dropped"]).optional(), mine: z.boolean().optional() },
    (c, a) => store.listTasks({ goal: a.goal ? Store.parseGoal(a.goal) : undefined, repo: a.repo, status: a.status,
      session: a.mine ? c.session : undefined }).map(line).join("\n") || "No tasks.");

  const planTask = z.object({ key: z.string(), title: z.string(), body: z.string().optional(), repo: z.string(),
    needs: z.array(z.string()).optional().describe("Keys of tasks listed before this one"), readonly: z.boolean().optional() });

  tool("goal_propose",
    "Propose a goal: a clear outcome, often across repositories. The body should say what done looks like and which repositories are involved. Tasks are optional: the coordinator that runs the goal plans and manages them itself; list some only when you already know them. The user sees it in Mission control and starts it; a coordinator then runs it in its own session. Don't start the work yourself.",
    { title: z.string(), body: z.string(), tasks: z.array(planTask).optional(),
      issues: z.array(z.string()).optional().describe("GitHub issues this goal resolves: owner/repo#12") },
    (c, a) => {
      const g = store.proposeGoal(c, { title: a.title, body: a.body, tasks: a.tasks ?? [] });
      for (const ref of a.issues ?? []) {
        const p = parseIssueRef(ref);
        if (!p) throw new Error(`not an issue reference: ${ref} (use owner/repo#12)`);
        store.linkIssue(g.id, p);
      }
      return `${Store.gid(g.id)} proposed; the user will start it.`;
    });

  tool("worktree_remove",
    "Coordinator only: remove a finished task's worktree and its local branch, once its work is merged (check gh pr view) or no longer wanted, and its worker is closed. Flightdeck runs it and tells you the result in your inbox.",
    { task: z.string() },
    (c, a) => `${store.tref(store.requestWorktreeRemoval(c, store.taskId(a.task)).id)}: removal queued; the result arrives in your inbox.`);

  tool("goal_complete",
    "Coordinator only: finish your goal when you're satisfied nothing is left to do: every task finished, every worker closed, worktrees removed (or kept, each with a reason, e.g. a PR still in review), and no question waiting for the user. Waiting for the user's direction is not done: ask_user and keep going. The summary goes to the user and to linked issues.",
    { summary: z.string().describe("What was done, PRs and their state, anything left for the user"),
      keep: z.array(z.object({ task: z.string(), reason: z.string() })).optional().describe("Worktrees to leave in place, with why") },
    (c, a) => {
      const g = store.completeGoal(c, { summary: a.summary, keep: a.keep?.map((k) => ({ task: store.taskId(k.task), reason: k.reason })) });
      goalFinished(store, g.id, a.summary);
      return `${Store.gid(g.id)} complete. Its session closes shortly; thank you.`;
    });

  tool("issue_link",
    "Link a GitHub issue (owner/repo#12) to a goal: the goal you coordinate or work on, or `goal` (G3). Linked issues are listed in briefs and get comments when the goal starts and finishes.",
    { issue: z.string(), goal: z.string().optional() },
    (c, a) => {
      const p = parseIssueRef(a.issue);
      if (!p) throw new Error("use owner/repo#12");
      const goal = a.goal ? Store.parseGoal(a.goal)
        : (store.listTasks({ session: c.session }).find((t) => t.goal != null)?.goal ?? null);
      if (goal == null) throw new Error("you aren't on a goal; pass goal");
      store.linkIssue(goal, p);
      return `${a.issue} linked to ${Store.gid(goal)}.`;
    });

  tool("goal_branch",
    "Coordinator only: collect this goal's work in `repo` on one branch you own, for one PR at the end instead of one per task. Create the branch first; workers started afterwards in that repo branch from it, commit without pushing, and you merge each finished one into it. branch omitted: back to a PR per task.",
    { repo: z.string(), branch: z.string().optional() },
    (c, a) => {
      if (a.branch) {
        const path = store.repoPath(a.repo);
        if (!path) throw new Error(`Flightdeck doesn't know repository ${a.repo}`);
        const found = Bun.spawnSync(["git", "-C", path, "rev-parse", "--verify", "--quiet", `refs/heads/${a.branch}`]);
        if (found.exitCode !== 0) throw new Error(`${a.repo} has no branch ${a.branch}: create it first (wt -C ${path} switch --create ${a.branch} --base <default branch>)`);
      }
      const g = store.setGoalBranch(c.session, a.repo, a.branch ?? null);
      return a.branch ? `${Store.gid(g.id)}'s work in ${a.repo} collects on ${a.branch}; workers you start there from now branch from it.`
        : `${Store.gid(g.id)}'s workers in ${a.repo} open their own PRs again.`;
    });

  tool("goal_join",
    "Coordinator only: your first call. Makes you the coordinator of the goal named in your brief.",
    { goal: z.string() },
    (c, a) => {
      const g = store.joinGoal(c, Store.parseGoal(a.goal));
      const others = store.otherGoals(g.id);
      const branches = store.goalBranches(g.id);
      return `You coordinate ${Store.gid(g.id)}: ${g.title}.\n` + store.listTasks({ goal: g.id }).map(line).join("\n")
        + (branches.length ? `\n\nGoal branches: ${branches.map((b) => `${b.repo}: ${b.branch}`).join(", ")}` : "")
        + (others ? `\n\nOther goals running now (message one by its id, e.g. to "G4", to reach its coordinator):\n${others}` : "");
    });

  const editTask = z.object({ task: z.string(), title: z.string().optional(), body: z.string().optional(), repo: z.string().optional(),
    needs: z.array(z.string()).optional().describe("Replaces what it waits for: task ids, or keys added in this call") });

  tool("goal_plan",
    "Shape a goal's plan: your own as its coordinator, or (with `goal`) any goal not started yet, such as one you proposed. title/body rewrite the goal; delete: true removes a goal not started (a duplicate or one nobody wants) with its tasks; add tasks (needs may name existing task ids or keys added in this call), edit tasks (title and body any time; repo and needs before they start), drop tasks. Returns the plan.",
    { goal: z.string().optional().describe("G3: a proposed goal to change; omit for the goal you coordinate"),
      title: z.string().optional(), body: z.string().optional(), delete: z.boolean().optional(),
      add: z.array(planTask).optional(), edit: z.array(editTask).optional(), drop: z.array(z.string()).optional() },
    (c, a) => {
      const g = store.planTarget(c.session, a.goal);
      if (a.delete) { store.deleteGoal(g.id); return `${Store.gid(g.id)} deleted.`; }
      store.editGoal(g.id, { title: a.title, body: a.body });
      const keys = new Map<string, number>();
      for (const t of a.add ?? []) {
        const needs = (t.needs ?? []).map((n) => keys.get(n) ?? store.taskId(n));
        keys.set(t.key, store.addTask(c, { title: t.title, body: t.body, repo: t.repo, goal: g.id, needs, readonly: t.readonly }).id);
      }
      for (const e of a.edit ?? []) {
        store.editTask(g.id, store.taskId(e.task), { title: e.title, body: e.body, repo: e.repo,
          needs: e.needs?.map((n) => keys.get(n) ?? store.taskId(n)) });
      }
      for (const ref of a.drop ?? []) store.dropTask(g.id, store.taskId(ref));
      const goal = store.goal(g.id);
      return `${Store.gid(goal.id)} [${goal.status}] ${goal.title}\n` + (store.listTasks({ goal: g.id }).map(line).join("\n") || "No tasks yet.");
    });

  tool("worker_start",
    "Coordinator only: start an omp worker on a task that's ready, or done/failed for follow-up work (it reopens; the worker continues in the task's worktree). Flightdeck opens it as a tab in the goal's session, in its own worktree (read-only tasks may use the checkout). `context` is added to its brief: what it should know from you or earlier workers. At most 4 open workers per goal.",
    { task: z.string(), context: z.string().optional() },
    (c, a) => `${Store.wid(store.requestWorker(c, store.taskId(a.task), a.context).id)} requested for ${a.task}; its done arrives in your inbox.`);

  tool("worker_stop",
    "Coordinator only: close a task's worker (its tab and omp session; the worktree stays). Use it once a finished worker's result is read. An unfinished task goes back to ready; a finished one stays finished.",
    { task: z.string() },
    (c, a) => {
      const w = store.stopWorker(c, store.taskId(a.task));
      const t = store.task(w.task);
      return `${Store.wid(w.id)} closing; ${a.task} is ${t.status}.`;
    });

  const INBOX_MAX_S = 25;
  server.registerTool("inbox", {
    // omp gives up on an MCP call after 30 s, and messages are returned once: a
    // longer wait would lose them. Coordinators call again to keep waiting.
    description: "Coordinator only: wait up to 25 s (timeout_s) for workers' done messages, messages to @coordinator, goal status, and the user's answers to your questions. Returns them once; nothing new means call it again to keep waiting.",
    inputSchema: { timeout_s: z.number().int().min(1).max(INBOX_MAX_S).optional() },
  }, async (args: { timeout_s?: number }) => {
    const caller = resolve();
    if (!caller) return fail(NO_CALLER);
    const until = Date.now() + (args.timeout_s ?? INBOX_MAX_S) * 1000;
    try {
      for (;;) {
        const events = store.inbox(caller.session);
        if (events.length) return ok(events.map((e) => `${e.task ? store.tref(e.task) : "goal"} · ${e.kind}: ${e.body}`).join("\n\n"));
        if (Date.now() >= until) return ok("Nothing yet.");
        await Bun.sleep(1000);
      }
    } catch (e) { return fail((e as Error).message); }
  });

  return server;
}
