import { afterAll, beforeAll, expect, test } from "bun:test";
import { startServer } from "../src/main";

let stop: () => void;
const base = "http://127.0.0.1:18095";
const token = "test-token";
const auth = { Authorization: `Bearer ${token}` };

beforeAll(() => {
  stop = startServer({ port: 18095, dbPath: ":memory:", token,
    resolve: (pane) => (pane === "42" ? { session: "s42", repo: "overseer", branch: "main", cwd: "/r", root: "/r" } : null) });
});
afterAll(() => stop());

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
  const body = await r.json() as { result: { content: { text: string }[] } };
  expect(body.result.content[0].text).toContain("T-1");
  const state = await (await fetch(`${base}/api/state`, { headers: auth })).json() as { tasks: { session: string }[] };
  expect(state.tasks[0].session).toBe("s42");
});

test("answers become deliveries for the task's session", async () => {
  await fetch(`${base}/api/answer`, { method: "POST", headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ task: "T-1", body: "go ahead" }) });
  const deliveries = await (await fetch(`${base}/api/deliveries`, { headers: auth })).json() as { session: string; text: string }[];
  expect(deliveries[0].session).toBe("s42");
  expect(deliveries[0].text).toContain("go ahead");
});

test("bad input is a 400 with the reason", async () => {
  const r = await fetch(`${base}/api/answer`, { method: "POST", headers: { ...auth, "Content-Type": "application/json" }, body: "{}" });
  expect(r.status).toBe(400);
  expect((await r.json() as { error: string }).error).toContain("missing task");
});

test("pane ids map to the omp sessions running in them", async () => {
  const r = await fetch(`${base}/api/panes`, { method: "POST", headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ panes: ["42", "7"] }) });
  expect(await r.json()).toEqual({ s42: "42" });
});

test("state lists goal sessions", async () => {
  const state = await (await fetch(`${base}/api/state`, { headers: auth })).json() as { goalSessions: string[] };
  expect(Array.isArray(state.goalSessions)).toBe(true);
});
