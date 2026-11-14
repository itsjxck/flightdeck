// Demo scenarios for Mission control: three small fake repositories and
// three proposed goals across them, for trying goals end to end with real
// agents. Start a goal from Mission control; its coordinator and workers do
// the work in worktrees (~/worktrees/demo-*).
//
//   bun scripts/demo.ts          create the repos (if missing) and propose the goals
//   bun scripts/demo.ts --reset  drop the demo goals and tasks, delete the repos and their worktrees
//
// Writes the server's database directly (it uses WAL, so the running server is fine).
// Close a started goal's session with Close goal in the sidebar first.
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { Store, type Caller } from "../src/store.ts";

const DATA = join(homedir(), "Library/Application Support/Tern/plugin-data/overseer");
const ROOT = join(homedir(), "projects/overseer-demo");
const REPOS: Record<string, Record<string, string>> = {
  "demo-payments": {
    "README.md": "# demo-payments\n\nPayments API for the demo shop. Bun, no dependencies.\n\nRun: `bun src/server.ts`. Test: `bun test`.\n",
    "package.json": JSON.stringify({ name: "demo-payments", private: true, type: "module", scripts: { test: "bun test" } }, null, 2) + "\n",
    "src/server.ts": `import { charge } from "./charge.ts";

// POST /charge {amount, currency, method: "card"} -> {id, status}
export function handle(req: Request): Promise<Response> | Response {
  const url = new URL(req.url);
  if (req.method === "POST" && url.pathname === "/charge") {
    return req.json().then((body) => Response.json(charge(body)));
  }
  return new Response("not found", { status: 404 });
}

if (import.meta.main) Bun.serve({ port: 4100, fetch: handle });
`,
    "src/charge.ts": `export type Method = "card";
export type Charge = { amount: number; currency: string; method: Method };

let next = 1;
export function charge(c: Charge): { id: string; status: "succeeded" | "declined" } {
  if (c.method !== "card") throw new Error("unsupported method " + c.method);
  if (c.amount <= 0) return { id: "ch_" + next++, status: "declined" };
  return { id: "ch_" + next++, status: "succeeded" };
}
`,
    "src/login.ts": `// POST /login {email, password}: no rate limiting yet.
export function login(email: string, password: string): boolean {
  return email.length > 0 && password === "hunter2";
}
`,
    "test/charge.test.ts": `import { expect, test } from "bun:test";
import { charge } from "../src/charge.ts";

test("card charges succeed", () => {
  expect(charge({ amount: 500, currency: "gbp", method: "card" }).status).toBe("succeeded");
});
`,
  },
  "demo-storefront": {
    "README.md": "# demo-storefront\n\nThe demo shop's web front end: plain HTML and TypeScript.\n",
    "package.json": JSON.stringify({ name: "demo-storefront", private: true, type: "module", scripts: { test: "bun test" } }, null, 2) + "\n",
    "src/checkout.ts": `// Builds the checkout's payment buttons. Card only for now.
export type PaymentOption = { id: string; label: string; icon: string };

export function paymentOptions(): PaymentOption[] {
  return [{ id: "card", label: "Pay by card", icon: "card" }];
}
`,
    "src/theme.css": `:root {
  --bg: #ffffff;
  --text: #1a1a1a;
  --brand: #3d6fff;
}
body { background: var(--bg); color: var(--text); }
`,
    "test/checkout.test.ts": `import { expect, test } from "bun:test";
import { paymentOptions } from "../src/checkout.ts";

test("card is offered", () => {
  expect(paymentOptions().map((o) => o.id)).toContain("card");
});
`,
  },
  "demo-design-system": {
    "README.md": "# demo-design-system\n\nColour tokens and icons shared by the demo shop's apps.\n",
    "package.json": JSON.stringify({ name: "demo-design-system", private: true, type: "module", scripts: { test: "bun test" } }, null, 2) + "\n",
    "src/tokens.ts": `// Colour tokens. Light theme only for now.
export const tokens = {
  bg: "#ffffff",
  text: "#1a1a1a",
  brand: "#3d6fff",
} as const;
`,
    "src/icons.ts": `// Icon names and their SVG paths.
export const icons: Record<string, string> = {
  card: "M2 6h20v12H2z M2 10h20",
};
`,
    "test/tokens.test.ts": `import { expect, test } from "bun:test";
import { tokens } from "../src/tokens.ts";

test("brand colour is set", () => {
  expect(tokens.brand).toMatch(/^#/);
});
`,
  },
};

const GOALS = [
  {
    title: "Add Apple Pay to checkout",
    body: "Shoppers can pay with Apple Pay. The payments API accepts the new method, the design system has its icon, and the storefront offers it. Keep it a demo: no real Apple Pay calls.",
    tasks: [
      { key: "api", repo: "demo-payments", title: "Accept apple_pay in /charge",
        body: "Add \"apple_pay\" to Method in src/charge.ts and handle it like card. Add a test." },
      { key: "icon", repo: "demo-design-system", title: "Add an apple-pay icon",
        body: "Add an \"apple-pay\" entry to src/icons.ts (any simple path)." },
      { key: "ui", repo: "demo-storefront", title: "Offer Apple Pay at checkout", needs: ["api", "icon"],
        body: "Add an Apple Pay option to paymentOptions() in src/checkout.ts using the apple-pay icon. Update the test." },
    ],
  },
  {
    title: "Dark mode",
    body: "The shop follows the system's dark mode. Tokens come from the design system; the storefront uses them.",
    tasks: [
      { key: "tokens", repo: "demo-design-system", title: "Add dark theme tokens",
        body: "Add a dark variant of tokens in src/tokens.ts. Before choosing the dark brand colour, ask the user (ask_user) whether to keep #3d6fff or use a lighter #5a8cff, recommending the lighter one." },
      { key: "css", repo: "demo-storefront", title: "Use dark tokens when the system is dark", needs: ["tokens"],
        body: "Add a prefers-color-scheme: dark block to src/theme.css using the new dark tokens." },
    ],
  },
  {
    title: "Rate-limit login",
    body: "Stop password guessing on /login.",
    tasks: [
      { key: "limit", repo: "demo-payments", title: "Rate-limit login attempts",
        body: "Add rate limiting to src/login.ts with a test. First ask the user (ask_user) whether to limit per IP address or per account, and how many attempts per minute (offer 5 and 10)." },
    ],
  },
];

function sh(cmd: string[], cwd: string) {
  const r = Bun.spawnSync(cmd, { cwd, stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")} failed in ${cwd}: ${r.stderr.toString()}`);
}

const store = new Store(join(DATA, "overseer.db"));
const names = Object.keys(REPOS);

if (process.argv.includes("--reset")) {
  const ph = names.map(() => "?").join(", ");
  const goals = store.db.query(`select distinct goal from tasks where repo in (${ph}) and goal is not null`).all(...names) as { goal: number }[];
  store.db.query(`update tasks set status = 'dropped' where repo in (${ph}) and status not in ('done', 'failed', 'dropped')`).run(...names);
  for (const { goal } of goals) store.db.query("update goals set status = 'dropped' where id = ? and status in ('proposed', 'active')").run(goal);
  store.db.query(`update events set handled = 1 where kind = 'question' and handled is null and task in (select id from tasks where repo in (${ph}))`).run(...names);
  store.db.query(`delete from repos where name in (${ph})`).run(...names);
  rmSync(ROOT, { recursive: true, force: true });
  for (const n of names) rmSync(join(homedir(), "worktrees", n), { recursive: true, force: true });
  console.log(`Dropped ${goals.length} demo goals; removed ${ROOT} and ~/worktrees/demo-*.`);
  process.exit(0);
}

for (const [name, files] of Object.entries(REPOS)) {
  const dir = join(ROOT, name);
  if (!existsSync(dir)) {
    for (const [file, content] of Object.entries(files)) {
      mkdirSync(dirname(join(dir, file)), { recursive: true });
      writeFileSync(join(dir, file), content);
    }
    sh(["git", "init", "-q", "-b", "main"], dir);
    sh(["git", "add", "."], dir);
    sh(["git", "commit", "-q", "-m", "Initial commit"], dir);
  }
  store.learnRepo(name, dir);
}

const caller: Caller = { session: "demo", repo: null, branch: null, cwd: ROOT };
for (const g of GOALS) {
  const goal = store.proposeGoal(caller, g);
  console.log(`${Store.gid(goal.id)} proposed: ${g.title}`);
}
store.addTask(caller, { title: "Write a README section on running the demo shop locally", repo: "demo-storefront" });
console.log(`Repos in ${ROOT}. Open Mission control to start a goal.`);
