// overseer-server: one process on 127.0.0.1 serving MCP (/mcp) to omp agents
// and a JSON API (/api) to Overseer, all behind a bearer token.
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Store, type Caller } from "./store";
import { buildServer } from "./tools";
import { handleApi } from "./api";
import { resolveCaller, resolvePane } from "./identity";

export function startServer(opts: { port: number; dbPath: string; token: string; resolve?: (pane: string) => Caller | null }) {
  const store = new Store(opts.dbPath);
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
        return transport.handleRequest(req);
      }
      if (url.pathname.startsWith("/api/")) return handleApi(store, req, url, resolve);
      return new Response("not found", { status: 404 });
    },
  });
  return () => server.stop(true);
}

// `bun src/main.ts <data dir>`: Overseer passes its plugin data directory.
if (import.meta.main) {
  const dir = process.argv[2] ?? join(process.env.HOME ?? ".", ".local/share/overseer");
  mkdirSync(dir, { recursive: true });
  const tokenPath = join(dir, "token");
  if (!existsSync(tokenPath)) writeFileSync(tokenPath, crypto.randomUUID().replaceAll("-", ""), { mode: 0o600 });
  const token = readFileSync(tokenPath, "utf8").trim();
  const port = Number(process.env.OVERSEER_PORT ?? 8095);
  startServer({ port, dbPath: join(dir, "overseer.db"), token });
  console.log(`overseer-server on 127.0.0.1:${port}, data in ${dir}`);
}
