import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Store } from "../src/store";
import { analytics, localDay, recordSample, scanUsage } from "../src/analytics";

const ID = "01a1e523-a1d7-72e2-a585-d651897a43d2";
const reply = (cost: number, model = "m1") => JSON.stringify({ type: "message", timestamp: new Date().toISOString(),
  message: { role: "assistant", model, usage: { totalTokens: 100, cost: { total: cost } } } }) + "\n";

test("usage is read once, incrementally, and credited to the task's goal", async () => {
  const root = mkdtempSync(join(tmpdir(), "usage-"));
  mkdirSync(join(root, "-p"), { recursive: true });
  const file = join(root, "-p", `t_${ID}.jsonl`);
  writeFileSync(file, JSON.stringify({ type: "session", id: ID, cwd: "/w/web-app" }) + "\n" + reply(0.5));
  const store = new Store(":memory:");
  const g = store.proposeGoal({ session: ID, repo: null, branch: null, cwd: null }, { title: "g", body: "", tasks: [] });
  store.startTask({ session: ID, repo: "web-app", branch: null, cwd: "/w/web-app" }, { title: "t" });
  store.db.query("update tasks set goal = ?").run(g.id);
  await scanUsage(store, root);
  appendFileSync(file, reply(0.25, "m2") + '{"partial":');
  await scanUsage(store, root);
  await scanUsage(store, root);
  const a = analytics(store);
  expect(a.spend.today).toBeCloseTo(0.75);
  expect(a.byModel.map((m) => m.model)).toEqual(["m1", "m2"]);
  expect(a.byGoal[0].cost).toBeCloseTo(0.75);
  expect(a.spendByDay.at(-1)).toEqual({ day: localDay(Date.now()), cost: 0.75 });
});

test("agent samples feed the last 24 hours, busiest per hour", () => {
  const store = new Store(":memory:");
  recordSample(store, { total: 3, working: 1, waiting: 0 }, Date.now() - 1000);
  recordSample(store, { total: 4, working: 2, waiting: 1 }, Date.now() - 500);
  const a = analytics(store);
  expect(a.agentsByHour.at(-1)).toMatchObject({ working: 2, total: 4 });
  expect(a.agentsNow).toMatchObject({ working: 2 });
});
