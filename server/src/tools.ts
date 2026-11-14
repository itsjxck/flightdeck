// The MCP tools agents see. Each resolves its caller (the omp session in the
// calling pane) and turns a broken rule into a tool error the agent can read.
// Descriptions carry the rules, so agents need no separate skill.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { Store, type Caller, type Task } from "./store";

type Resolve = () => Caller | null;

const ok = (text: string) => ({ content: [{ type: "text" as const, text }] });
const fail = (text: string) => ({ content: [{ type: "text" as const, text }], isError: true });
const NO_CALLER = "Couldn't tell which omp session is calling: run omp inside a Tern pane.";

function line(t: Task) {
  return `${Store.tid(t.id)} [${t.status}] ${t.title}${t.repo ? ` (${t.repo})` : ""}${t.goal ? ` · ${Store.gid(t.goal)}` : ""}`;
}

export function buildServer(store: Store, resolve: Resolve): McpServer {
  const server = new McpServer({ name: "overseer", version: "1.0.0" });

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

  const id = z.string().optional().describe("Task id (T-12); defaults to your only task in progress");

  tool("task_start",
    "Start tracking the work you're doing. Call once at the start of any task that changes something, with a short imperative title. A worker's brief names an existing task: pass its id instead.",
    { title: z.string().optional(), body: z.string().optional().describe("Two or three sentences on the goal, Markdown"),
      id: z.string().optional(), readonly: z.boolean().optional().describe("Research or review only, no changes") },
    (c, a) => line(store.startTask(c, { id: a.id ? Store.parseTask(a.id) : undefined, title: a.title, body: a.body, readonly: a.readonly })) + " — started.");

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

  const INBOX_MAX_S = 25;
  server.registerTool("inbox", {
    // omp gives up on an MCP call after 30 s, and messages are returned once: a
    // longer wait would lose them. Coordinators call again to keep waiting.
    description: "Coordinator only: wait up to 25 s (timeout_s) for workers' done messages, messages to @coordinator and goal status. Returns them once; nothing new means call it again to keep waiting.",
    inputSchema: { timeout_s: z.number().int().min(1).max(INBOX_MAX_S).optional() },
  }, async (args: { timeout_s?: number }) => {
    const caller = resolve();
    if (!caller) return fail(NO_CALLER);
    const until = Date.now() + (args.timeout_s ?? INBOX_MAX_S) * 1000;
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
