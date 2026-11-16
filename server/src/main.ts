// flightdeck-server: one process on 127.0.0.1 serving MCP (/mcp) to omp agents
// and a JSON API (/api) to Flightdeck, all behind a bearer token.
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Store, type Caller } from "./store";
import { buildServer } from "./tools";
import { handleApi } from "./api";
import { resolveCaller, resolvePane } from "./identity";
import { loadConfig, scanRepos, type ScanConfig } from "./repos";
import { scanUsage } from "./analytics";
import { Events } from "./events";

const RESCAN_MS = 30 * 60_000;
const USAGE_MS = 5 * 60_000;
// Finished goals and tasks older than this are deleted (checked at start and with each rescan).
const KEEP_FINISHED_MS = 30 * 24 * 60 * 60_000;

export function startServer(opts: { port: number; dbPath: string; token: string; resolve?: (pane: string) => Caller | null; scan?: ScanConfig }) {
  const store = new Store(opts.dbPath);
  const events = new Events();
  // Repository discovery: at start, every RESCAN_MS, and on demand (POST /api/repos/scan).
  const scan = async () => {
    if (!opts.scan) return { added: 0, removed: 0, duplicates: [] };
    const result = store.syncScanned(await scanRepos(opts.scan));
    // Repositories learned from agents whose folder has since been deleted.
    for (const r of store.repos({ ignored: true })) if (!existsSync(r.path)) { store.forgetRepo(r.name); result.removed++; }
    console.log(`repos: ${result.added} added, ${result.removed} removed, ${result.duplicates.length} name clashes`);
    return result;
  };
  const tidy = () => {
    const r = store.cleanup(Date.now() - KEEP_FINISHED_MS);
    if (r.goals || r.tasks) console.log(`cleanup: ${r.goals} goals, ${r.tasks} tasks finished 30+ days ago deleted`);
  };
  tidy();
  scan().catch((e) => console.error("repo scan failed:", e));
  // omp's spend: read new usage from its session files now and every USAGE_MS.
  const usage = () => scanUsage(store).catch((e) => console.error("usage scan failed:", e));
  if (opts.scan) { usage(); }
  const usageTimer = setInterval(() => { if (opts.scan) usage(); }, USAGE_MS);
  const rescan = setInterval(() => { tidy(); scan().catch((e) => console.error("repo scan failed:", e)); }, RESCAN_MS);
  const resolve = opts.resolve ?? resolvePane;
  const resolveTool = opts.resolve ?? resolveCaller;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: opts.port,
    idleTimeout: 0, // inbox holds a request up to 25 s
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/health") return Response.json({ ok: true });
      if (req.headers.get("authorization") !== `Bearer ${opts.token}`) return new Response("unauthorized", { status: 401 });
      if (url.pathname === "/mcp") {
        const pane = req.headers.get("x-tern-pane") ?? "";
        // Stateless: a fresh server and transport per request.
        const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
        await buildServer(store, () => (pane ? resolveTool(pane) : null)).connect(transport);
        const res = await transport.handleRequest(req);
        // An agent's tool call may have changed anything (a question, a done, a worker request).
        events.changed();
        return res;
      }
      if (url.pathname === "/api/events") return events.response();
      if (url.pathname === "/api/repos/scan" && req.method === "POST") { const r = await scan(); events.changed(); return Response.json(r); }
      if (url.pathname.startsWith("/api/")) {
        const res = await handleApi(store, req, url, resolve);
        // Panes and samples are the window's bookkeeping, not changes anyone needs to see.
        if (req.method === "POST" && !url.pathname.startsWith("/api/panes") && !url.pathname.startsWith("/api/samples")) events.changed();
        return res;
      }
      return new Response("not found", { status: 404 });
    },
  });
  return () => { clearInterval(rescan); clearInterval(usageTimer); events.stop(); server.stop(true); };
}

// `bun src/main.ts <data dir>`: Flightdeck passes its plugin data directory.
if (import.meta.main) {
  // FLIGHTDECK_LOG: append output there (Flightdeck sets it; a terminal run keeps stdout).
  const logPath = process.env.FLIGHTDECK_LOG;
  if (logPath) {
    const write = (...args: unknown[]) => appendFileSync(logPath, args.map(String).join(" ") + "\n");
    console.log = write;
    console.error = write;
  }
  const dir = process.argv[2] ?? join(process.env.HOME ?? ".", ".local/share/flightdeck");
  mkdirSync(dir, { recursive: true });
  const tokenPath = join(dir, "token");
  if (!existsSync(tokenPath)) writeFileSync(tokenPath, crypto.randomUUID().replaceAll("-", ""), { mode: 0o600 });
  const token = readFileSync(tokenPath, "utf8").trim();
  const port = Number(process.env.FLIGHTDECK_PORT ?? 8095);
  startServer({ port, dbPath: join(dir, "flightdeck.db"), token, scan: loadConfig(dir) });
  console.log(`flightdeck-server on 127.0.0.1:${port}, data in ${dir}`);
}
