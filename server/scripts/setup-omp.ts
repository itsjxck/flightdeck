// Connects omp to Flightdeck's server, once per machine. Run by the palette
// command "Connect omp to Flightdeck" (window.luau), or by hand:
//
//   bun scripts/setup-omp.ts "<plugin data dir>"
//
// 1. ~/.omp/agent/mcp.json gets a `flightdeck` MCP server: Flightdeck's local
//    server, with the caller's Tern pane (identity) and the access token
//    (read from the data dir when omp starts, so it's never copied).
// 2. ~/.omp/agent/AGENTS.md gets a short note telling every omp agent to
//    track its work with the tools, between markers so a rerun replaces it.
// Everything else in both files is left as it is.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const dataDir = process.argv[2];
if (!dataDir) throw new Error("usage: bun scripts/setup-omp.ts <plugin data dir>");
const port = Number(process.env.FLIGHTDECK_PORT ?? 8095);
const agentDir = join(homedir(), ".omp/agent");
mkdirSync(agentDir, { recursive: true });

// 1. The MCP server.
const mcpPath = join(agentDir, "mcp.json");
const mcp: { mcpServers?: Record<string, unknown> } = existsSync(mcpPath) ? JSON.parse(readFileSync(mcpPath, "utf8")) : {};
mcp.mcpServers ??= {};
mcp.mcpServers.flightdeck = {
  type: "http",
  url: `http://127.0.0.1:${port}/mcp`,
  headers: {
    "X-Tern-Pane": "${TERN_PANE}",
    Authorization: `!printf 'Bearer %s' "$(cat '${join(dataDir, "token")}')"`,
  },
};
writeFileSync(mcpPath, JSON.stringify(mcp, null, 2) + "\n");

// 2. The agents' note.
const START = "<!-- flightdeck -->", END = "<!-- /flightdeck -->";
const hasSecurityKey = (() => { try { return readdirSync(join(homedir(), ".ssh")).some((f) => /^id_\w+_sk$/.test(f)); } catch { return false; } })();
const note = [
  START,
  "# Work tracking",
  "",
  "When running in Tern with the `flightdeck` MCP tools: call `task_start` at the start of any task that changes something, `task_note` at real milestones, `ask_user` for any decision you need from the user (also ask in your pane), and `task_done` exactly once at the end. The tool descriptions have the details.",
  ...(hasSecurityKey ? ["", "# SSH security key", "",
    "Git over SSH (push, fetch, pull, clone) uses the user's hardware security key, which needs unlocking (touch or PIN) now and then. If an SSH operation fails with \"incorrect passphrase\", \"signing failed\", \"agent refused operation\" or \"Permission denied (publickey)\", don't work around it: no HTTPS remotes, no new keys, no changing remotes or SSH config. Ask the user to unlock their security key (with `ask_user` when the flightdeck tools are available), then retry."] : []),
  END,
].join("\n");
const agentsPath = join(agentDir, "AGENTS.md");
const agents = existsSync(agentsPath) ? readFileSync(agentsPath, "utf8") : "";
const block = new RegExp(`${START}[\\s\\S]*?${END}`);
writeFileSync(agentsPath, block.test(agents) ? agents.replace(block, note) : (agents.trimEnd() ? agents.trimEnd() + "\n\n" : "") + note + "\n");

console.log(`omp connected: mcp.json has "flightdeck" (port ${port}); AGENTS.md has the work-tracking note. Restart running omp agents to load the tools.`);
