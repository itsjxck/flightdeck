import { expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Store } from "../src/store";
import { buildServer } from "../src/tools";

async function connect(store: Store, session: string) {
  const caller = { session, repo: "flightdeck", branch: "main", cwd: "/r" };
  const server = buildServer(store, () => caller);
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  const client = new Client({ name: "test", version: "0" });
  await client.connect(b);
  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const r = await client.callTool({ name, arguments: args });
    const content = r.content as { type: string; text: string }[];
    return { text: content[0].text, error: r.isError === true };
  };
  return { client, call };
}

test("lists every tool from the spec", async () => {
  const { client } = await connect(new Store(":memory:"), "s");
  const names = (await client.listTools()).tools.map((t) => t.name).sort();
  expect(names).toEqual(["ask_user", "goal_complete", "goal_join", "goal_plan", "goal_propose", "inbox", "issue_link", "message",
    "task_add", "task_done", "task_list", "task_note", "task_start", "worker_start", "worker_stop", "worktree_remove"]);
});

test("start, ask, done through the tools", async () => {
  const store = new Store(":memory:");
  const { call } = await connect(store, "s");
  expect((await call("task_start", { title: "Fix tick" })).text).toContain("T1");
  expect((await call("ask_user", { question: "Which?", options: ["a", "b"], recommended: 1 })).text).toContain("waiting");
  expect(store.waiting().length).toBe(1);
  expect((await call("task_done", { outcome: "succeeded", summary: "fixed" })).text).toContain("finished");
});

test("rule errors come back as tool errors, not crashes", async () => {
  const { call } = await connect(new Store(":memory:"), "s");
  const r = await call("task_note", { body: "x" });
  expect(r.error).toBe(true);
  expect(r.text).toContain("task_start first");
});

test("a coordinator's inbox returns a worker's done", async () => {
  const store = new Store(":memory:");
  const g = store.proposeGoal({ session: "p", repo: null, branch: null, cwd: null },
    { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }] });
  store.startGoal(g.id);
  const coord = await connect(store, "coord");
  expect((await coord.call("goal_join", { goal: "G-1" })).text).toContain("You coordinate G1");
  expect((await coord.call("worker_start", { task: "T-1" })).text).toContain("W1 requested");
  const worker = await connect(store, "w");
  await worker.call("task_start", { id: "T-1" });
  await worker.call("task_done", { outcome: "succeeded", summary: "ok" });
  const inbox = await coord.call("inbox", { timeout_s: 1 });
  expect(inbox.text).toContain("G1.1 · done");
});
