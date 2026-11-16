// Seeds a Flightdeck for screenshots (scripts/showcase.sh runs it): small Git
// repositories with worktrees, goals in every state with tasks, notes, a
// question waiting, a linked issue, and two weeks of made-up omp usage and
// agent samples for Stats. Writes only under the given folders.
//
//   bun scripts/showcase.ts <plugin data dir> <showcase root>
//
// The task sessions are made-up ids; showcase.sh puts their agent states in
// the plugin's kv (`mission:agents`) so Mission control shows them working.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Store, type Caller } from "../src/store";
import { localDay, recordSample } from "../src/analytics";

const [dataDir, root] = process.argv.slice(2);
if (!dataDir || !root) throw new Error("usage: bun scripts/showcase.ts <plugin data dir> <showcase root>");
const DAY = 86_400_000;
const now = Date.now();

function sh(cmd: string[], cwd: string) {
  const r = Bun.spawnSync(cmd, { cwd, stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")}: ${r.stderr.toString()}`);
}

// ── Repositories, each with a couple of commits; some with worktrees ────────
const repos: Record<string, { files: Record<string, string>; worktrees: string[] }> = {
  payments: { files: { "README.md": "# payments\n\nCharges, refunds and payouts.\n", "src/charge.ts": "export const methods = [\"card\"];\n" },
    worktrees: ["g1.1-apple-pay-in-charge", "refund-webhooks"] },
  storefront: { files: { "README.md": "# storefront\n\nThe shop's web front end.\n", "src/checkout.ts": "export const options = [\"card\"];\n" },
    worktrees: [] },
  "design-system": { files: { "README.md": "# design-system\n\nColour tokens and icons.\n", "src/tokens.ts": "export const brand = \"#3d6fff\";\n" },
    worktrees: ["g1.2-apple-pay-icon", "g2.1-dark-theme-tokens"] },
  "platform-infra": { files: { "README.md": "# platform-infra\n\nClusters, DNS and CI.\n" }, worktrees: [] },
};
for (const [name, r] of Object.entries(repos)) {
  const dir = join(root, "repos", name);
  for (const [file, content] of Object.entries(r.files)) {
    mkdirSync(join(dir, file, ".."), { recursive: true });
    writeFileSync(join(dir, file), content);
  }
  sh(["git", "init", "-q", "-b", "main"], dir);
  sh(["git", "add", "."], dir);
  sh(["git", "-c", "user.name=Demo", "-c", "user.email=demo@example.com", "commit", "-q", "-m", "Initial commit"], dir);
  for (const branch of r.worktrees) sh(["git", "worktree", "add", "-q", "-b", branch, join(root, "worktrees", name, branch)], dir);
}
// A change in one worktree, so the sidebar shows its uncommitted mark.
writeFileSync(join(root, "worktrees", "payments", "refund-webhooks", "src", "charge.ts"), "export const methods = [\"card\", \"refund\"];\n");
writeFileSync(join(dataDir, "repos.json"), JSON.stringify({ roots: [join(root, "repos")], maxDepth: 2, skip: [] }));

// ── Goals and tasks ──────────────────────────────────────────────────────────
const store = new Store(join(dataDir, "flightdeck.db"));
for (const name of Object.keys(repos)) store.learnRepo(name, join(root, "repos", name));
const sid = (n: number) => `0195${String(n).padStart(4, "0")}-0000-7000-8000-${String(n).padStart(12, "0")}`;
const as = (session: string, repo: string | null = null, cwd: string | null = null): Caller => ({ session, repo, branch: null, cwd });
const at = (task: number, fields: Record<string, string | number | null>) => {
  const sets = Object.keys(fields).map((k) => `${k} = ?`).join(", ");
  store.db.query(`update tasks set ${sets} where id = ?`).run(...Object.values(fields), task);
};
const note = (session: string, task: number, body: string) => store.note(session, { ref: store.tref(task), body });

// G1: running, one task done, one in progress with a question for you, one waiting on both.
const g1 = store.proposeGoal(as("you"), {
  title: "Apple Pay at checkout",
  body: "Shoppers can pay with Apple Pay: the payments API accepts it, the design system has its icon, and checkout offers it.",
  tasks: [
    { key: "api", repo: "payments", title: "Accept apple_pay in /charge" },
    { key: "icon", repo: "design-system", title: "Add an apple-pay icon" },
    { key: "ui", repo: "storefront", title: "Offer Apple Pay at checkout", needs: ["api", "icon"] },
  ],
});
store.linkIssue(g1.id, { repo: "acme/storefront", number: 128, title: "Support Apple Pay", url: "https://github.com/acme/storefront/issues/128" });
store.startGoal(g1.id);
store.joinGoal(as(sid(10), "payments", join(root, "repos", "payments")), g1.id);
const [g1api, g1icon] = store.listTasks({ goal: g1.id }).filter((t) => t.session == null);
store.startTask(as(sid(11), "payments", join(root, "worktrees/payments/g1.1-apple-pay-in-charge")), { id: g1api.id });
note(sid(11), g1api.id, "**Charge path done:** apple_pay accepted alongside card; 14 tests pass.");
store.doneTask(sid(11), { ref: store.tref(g1api.id), outcome: "succeeded", summary: "apple_pay accepted; PR #212 merged." });
at(g1api.id, { branch: "g1.1-apple-pay-in-charge", pr: "https://github.com/acme/payments/pull/212" });
store.startTask(as(sid(12), "design-system", join(root, "worktrees/design-system/g1.2-apple-pay-icon")), { id: g1icon.id });
at(g1icon.id, { branch: "g1.2-apple-pay-icon" });
note(sid(12), g1icon.id, "Icon drawn at 16 and 24 px; checking contrast on dark surfaces.");
store.ask(sid(12), { ref: store.tref(g1icon.id), question: "Apple's brand rules allow the **black** or the **white** mark. Which should the icon use on dark surfaces?",
  options: ["White mark on dark, black on light", "Black mark everywhere, on a white chip"], recommended: 1 });
note(sid(10), store.listTasks({ goal: g1.id }).find((t) => t.session === sid(10))!.id, "G1.1 merged; G1.2 asked about the icon; G1.3 starts when both are done.");

// G2: running, early.
const g2 = store.proposeGoal(as("you"), {
  title: "Dark mode",
  body: "The shop follows the system's dark mode, using the design system's tokens.",
  tasks: [
    { key: "tokens", repo: "design-system", title: "Dark theme tokens" },
    { key: "css", repo: "storefront", title: "Use dark tokens when the system is dark", needs: ["tokens"] },
  ],
});
store.startGoal(g2.id);
store.joinGoal(as(sid(20), "storefront", join(root, "repos", "storefront")), g2.id);
const [g2tokens] = store.listTasks({ goal: g2.id }).filter((t) => t.session == null);
store.startTask(as(sid(21), "design-system", join(root, "worktrees/design-system/g2.1-dark-theme-tokens")), { id: g2tokens.id });
at(g2tokens.id, { branch: "g2.1-dark-theme-tokens" });
note(sid(21), g2tokens.id, "Surface, ink and accent tokens drafted; contrast AA everywhere, AAA for body text.");

// G3: proposed by an agent, linked to an issue. G4: completed yesterday.
const g3 = store.proposeGoal(as(sid(30), "payments"), { title: "Rate-limit login",
  body: "Stop password guessing on /login: per-account and per-IP limits, with a test.", tasks: [] });
store.linkIssue(g3.id, { repo: "acme/payments", number: 87, title: "Brute force on /login", url: "https://github.com/acme/payments/issues/87" });
const g4 = store.proposeGoal(as("you"), { title: "Order history page", body: "Signed-in shoppers see their past orders.", tasks: [
  { key: "a", repo: "payments", title: "List a shopper's charges" }, { key: "b", repo: "storefront", title: "Order history page", needs: ["a"] }] });
store.db.query("update tasks set status = 'done', updated = ? where goal = ?").run(now - DAY, g4.id);
store.db.query("update goals set status = 'done', closed = ? where id = ?").run(now - DAY, g4.id);

// Tasks outside goals: one in progress, one done today, one for later.
const t1 = store.startTask(as(sid(40), "platform-infra", join(root, "repos", "platform-infra")), { title: "Upgrade CI runners to Bun 1.4" });
note(sid(40), t1.id, "Runners rebuilt; 2 of 3 pipelines green, fixing a lockfile check.");
const t2 = store.startTask(as(sid(41), "storefront", join(root, "repos", "storefront")), { title: "Fix flaky checkout test" });
store.doneTask(sid(41), { ref: store.tref(t2.id), outcome: "succeeded", summary: "Seeded the clock; 50 runs green." });
store.addTask(as("you"), { title: "Document the refund webhook payloads", repo: "payments" });

// ── Stats: two weeks of made-up omp usage and agent samples ─────────────────
const sessions = join(root, "omp-sessions");
const projects = ["payments", "storefront", "design-system", "platform-infra"];
const models = ["claude-opus-5-5", "claude-sonnet-5"];
const sessionsOf: Record<string, string[]> = { payments: [sid(10), sid(11)], "design-system": [sid(12), sid(21)], storefront: [sid(20)], "platform-infra": [sid(40)] };
let seed = 7;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
for (const project of projects) {
  for (const session of sessionsOf[project]) {
    const dir = join(sessions, `-${project}`);
    mkdirSync(dir, { recursive: true });
    const lines = [JSON.stringify({ type: "session", id: session, cwd: join(root, "repos", project) })];
    for (let d = 13; d >= 0; d--) {
      const weekend = new Date(now - d * DAY).getDay() % 6 === 0;
      const replies = weekend ? 0 : Math.floor(rand() * 18);
      for (let i = 0; i < replies; i++) {
        const cost = 0.05 + rand() * 0.6;
        lines.push(JSON.stringify({ type: "message", timestamp: new Date(now - d * DAY - rand() * 8 * 3_600_000).toISOString(),
          message: { role: "assistant", model: rand() < 0.85 ? models[0] : models[1], usage: { totalTokens: Math.floor(cost * 160_000), cost: { total: cost } } } }));
      }
    }
    writeFileSync(join(dir, `${localDay(now)}_${session}.jsonl`), lines.join("\n") + "\n");
  }
}
for (let m = 24 * 60; m >= 0; m -= 5) {
  const hour = new Date(now - m * 60_000).getHours();
  const busy = hour >= 9 && hour <= 18;
  const working = busy ? 1 + Math.floor(rand() * 4) : Math.floor(rand() * 2);
  recordSample(store, { total: working + 2, working, waiting: rand() < 0.2 ? 1 : 0 }, now - m * 60_000);
}
console.log(`Showcase seeded in ${root}`);
