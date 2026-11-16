# Mission control, plan 2 of 4: Overseer runs the server and acts for it

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Overseer keeps `overseer-server` running, connects omp agents to it, delivers your answers and agents' messages to the right pane, opens goal sessions with their coordinator, and starts and stops workers in their own worktrees, all in the background.

**Architecture:** A new `mission.luau` module holds everything Overseer does for the server; `window.luau` only calls `mission.tick` from its tick and adds a palette command. Every server call is a `tern.fetch` with its own callback (50 ms budget). Sessions and tabs are opened with the `tern` CLI (`tern new session|tab … -- omp …`), which leaves your focus alone (checked 2026-11-14). A worker tab runs Worktrunk, which creates the task's worktree and then starts omp in it (`wt switch --create … -x omp -- <brief>`), so setup hooks and their approval prompts are visible in that tab.

**Tech Stack:** Luau (Tern plugin API), the `tern` and `wt` CLIs, `overseer-server` from plan 1 (Bun).

Spec: `docs/specs/2026-11-14-mission-control-design.md` §1, §2, §5, §7. Plan 1 built the server. Plan 3 adds the Mission control block and the sidebar sections; until then, a palette command starts proposed goals.

---

## File structure

| File | Change |
|---|---|
| `server/src/identity.ts` | Also returns the repository's root path; caches misses too |
| `server/src/store.ts` | `repos` table (name → root path), learned from every caller |
| `server/src/api.ts` | `POST /api/panes` (pane ids → session map); `repoPath` on worker starts |
| `server/test/*.test.ts` | Tests for the above |
| `mission.luau` (new) | API client, server lifecycle, deliveries, goal sessions, worker starts and stops |
| `window.luau` | `require("./mission")`; call `mission.tick` from the tick; palette command **Start proposed goal** |
| `README.md`, `CHANGELOG.md` | The server, connecting omp, goal sessions |

Luau has no test runner here: pure helpers in `mission.luau` get assert self-checks that run when the module loads (as `plane.luau` did), and each task ends with a live check through `tern` and `curl`.

---

### Task 1: Server: repository paths and pane lookup

**Files:**
- Modify: `server/src/identity.ts`, `server/src/store.ts`, `server/src/api.ts`, `server/src/tools.ts`
- Test: `server/test/store.test.ts`, `server/test/http.test.ts`, `server/test/identity.test.ts`

Overseer must turn a session into a pane (deliveries) and a repository name into a folder (worker starts). The server already resolves panes; it now also returns the repository root and remembers it per name.

- [ ] **Step 1: Write the failing tests**

```ts
// append to server/test/store.test.ts
describe("repositories", () => {
  test("callers teach the store where each repository lives", () => {
    const store = new Store(":memory:");
    store.learnRepo("api", "/Users/j/projects/api");
    store.learnRepo("api", "/Users/j/projects/api");
    expect(store.repoPath("api")).toBe("/Users/j/projects/api");
    expect(store.repoPath("unknown")).toBeNull();
  });
});
```

```ts
// append to server/test/http.test.ts
test("pane ids map to the omp sessions running in them", async () => {
  const r = await fetch(`${base}/api/panes`, { method: "POST", headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify({ panes: ["42", "7"] }) });
  expect(await r.json()).toEqual({ s42: "42" });
});
```

```ts
// append to server/test/identity.test.ts
import { repoRoot } from "../src/identity";
test("repository root from the common git dir", () => {
  expect(repoRoot("/Users/j/projects/api/.git")).toBe("/Users/j/projects/api");
});
```

In `http.test.ts`, change the resolver so pane 42 also has a root: `{ session: "s42", repo: "overseer", branch: "main", cwd: "/r", root: "/r" }`.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd server && bun test`
Expected: FAIL: `store.learnRepo is not a function`, `repoRoot` not exported, `/api/panes` 404.

- [ ] **Step 3: Implement**

In `store.ts`, add `root` to `Caller` and a table:

```ts
export interface Caller { session: string; repo: string | null; branch: string | null; cwd: string | null; root?: string | null }
```

Append to `SCHEMA`:

```sql
create table if not exists repos (name text primary key, path text not null);
```

Add to `Store`:

```ts
  learnRepo(name: string, path: string) {
    this.db.query("insert into repos (name, path) values (?, ?) on conflict(name) do update set path = excluded.path").run(name, path);
  }

  repoPath(name: string | null): string | null {
    if (!name) return null;
    const r = this.db.query("select path from repos where name = ?").get(name) as { path: string } | null;
    return r ? r.path : null;
  }
```

In `identity.ts`, export `repoRoot`, return `root`, and cache misses (shells and non-omp panes are asked about every 2 s):

```ts
export function repoRoot(commonGitDir: string): string {
  return dirname(commonGitDir);
}
```

Change the cache to `Map<string, { at: number; caller: Caller | null }>`; on a miss, `cache.set(pane, { at: Date.now(), caller: null })` before each `return null` after the cache check; set `root: common ? repoRoot(common) : null` on the caller.

In `tools.ts`, learn the repository on every call: inside the `tool` wrapper and `inbox`, after `const caller = resolve()` and the null check, add:

```ts
      if (caller.repo && caller.root) store.learnRepo(caller.repo, caller.root);
```

In `api.ts`, the resolver must reach the API: change the signature to `handleApi(store, req, url, resolve: (pane: string) => Caller | null)` (import `Caller`), pass `resolve` from `main.ts`, and add:

```ts
      case "POST panes": {
        const panes = Array.isArray(body.panes) ? body.panes.filter((p): p is string => typeof p === "string") : [];
        const map: Record<string, string> = {};
        for (const pane of panes) {
          const caller = resolve(pane);
          if (!caller) continue;
          map[caller.session] = pane;
          if (caller.repo && caller.root) store.learnRepo(caller.repo, caller.root);
        }
        return json(map);
      }
```

and in `GET workers`, add `repoPath: store.repoPath(t.repo)` to each start.

- [ ] **Step 4: Run every test**

Run: `cd server && bun test`
Expected: PASS, every file.

- [ ] **Step 5: Commit**

```bash
git add server/src server/test
git commit -m "overseer-server: repository paths and pane-to-session lookup"
```

---

### Task 2: mission.luau: API client and server lifecycle

**Files:**
- Create: `mission.luau`
- Modify: `window.luau` (require; call `mission.tick` from `tick`)

Overseer starts the server when `/health` fails and it has never seen it healthy, or after two failures in a row. The process outlives plugin reloads (Tern 0.9.16+), so a reload just finds it healthy. A second start while one is running exits on the busy port, harmlessly. Output goes to `server.log` in the plugin data directory.

- [ ] **Step 1: Write the module's first part**

```lua
-- mission.luau: what Overseer does for overseer-server (server/). Keeps the
-- server running, delivers answers and agents' messages to their panes,
-- opens goal sessions and starts workers. Every server call is a tern.fetch
-- with a callback of its own, so no callback nears Tern's 50 ms budget.
local oplog = require("./oplog")
local wt = require("./worktrunk")

local M = {}

local PORT = 8095
local BASE = "http://127.0.0.1:" .. PORT
local TERN = tern.getenv("TERN_EXE") or "/Applications/Tern.app/Contents/MacOS/tern"
local HEALTH_MS = 5000
local POLL_MS = 2000

local warned = {}
local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	tern.log.warn("Overseer Mission control: " .. message)
end

local token
local function readToken()
	if token then return token end
	local ok, text = pcall(tern.fs.read, tern.plugin.data .. "/token", 256)
	if ok then token = string.match(text, "^%s*(.-)%s*$") end
	return token
end

-- Calls the server's JSON API; fn(body, err, cx).
function M.api(method, path, body, fn)
	local t = readToken()
	if not t then fn(nil, "the server hasn't created its token yet", nil); return end
	tern.fetch(BASE .. path, {
		method = method, timeout_ms = 10000,
		headers = { Authorization = "Bearer " .. t, ["Content-Type"] = "application/json" },
		body = if body ~= nil then tern.json.encode(body) else nil,
	}, function(result, cx)
		if result.error then fn(nil, result.error, cx); return end
		local ok, decoded = pcall(tern.json.decode, result.body)
		if result.status ~= 200 then
			fn(nil, if ok and type(decoded) == "table" and decoded.error then decoded.error else "HTTP " .. tostring(result.status), cx)
			return
		end
		fn(if ok then decoded else nil, nil, cx)
	end)
end

local healthy, everHealthy, failures, starting, lastHealth = false, false, 0, false, -HEALTH_MS

local function startServer()
	starting = true
	-- Installs dependencies on first run, then replaces the shell with the server.
	local script = 'cd "$1" && { [ -d node_modules ] || bun install --frozen-lockfile; } && exec bun src/main.ts "$2" >>"$3" 2>&1'
	local ok, err = pcall(tern.process.run,
		{ "/bin/zsh", "-lc", script, "overseer-server", tern.plugin.dir .. "/server", tern.plugin.data, tern.plugin.data .. "/server.log" },
		{}, function(result)
			starting = false
			oplog.write("warn", { op = "server", event = "exited", detail = "status " .. tostring(result.status) })
		end)
	if not ok then starting = false; warnOnce("spawn", tostring(err)); return end
	oplog.write("info", { op = "server", event = "started" })
end

local function checkHealth()
	tern.fetch(BASE .. "/health", { timeout_ms = 3000 }, function(result)
		healthy = result.status == 200
		if healthy then everHealthy, failures = true, 0; return end
		failures += 1
		if not starting and (not everHealthy or failures >= 2) then startServer() end
	end)
end

-- Called from Overseer's tick. `panes`: every live terminal and agent pane id (strings).
function M.tick(cx, panes, hooks)
	if tern.now() - lastHealth >= HEALTH_MS then
		lastHealth = tern.now()
		checkHealth()
	end
end

return M
```

- [ ] **Step 2: Wire it into the tick**

In `window.luau`, after `local oplog = require("./oplog")`:

```lua
local mission = require("./mission")
```

In `tick`, after `separately(syncAgents)`:

```lua
	separately(function(tickCx)
		local live = {}
		for _, pane in tickCx.session:panes() do
			if pane.exited == nil and (pane.kind == "terminal" or pane.kind == "agent") then table.insert(live, tostring(pane.pane)) end
		end
		mission.tick(tickCx, live, missionHooks)
	end)
```

and above `tick` (filled in by later tasks):

```lua
-- What mission.luau needs from the window: the repositories Spaces knows
-- (`repos`, by id: {id, name, path, base}; `repoById` applies base overrides).
local function repoNamed(name)
	for id, repo in repos do
		if repo.name == name then return repoById(id) end
	end
	return nil
end
local missionHooks = {
	repoPath = function(name) local repo = repoNamed(name); return repo and repo.path end,
	baseFor = function(name) local repo = repoNamed(name); return repo and repo.base ~= "" and repo.base or nil end,
}
```

- [ ] **Step 3: Reload and check the server comes up**

Run: `tern plugin reload overseer && sleep 15 && curl -s 127.0.0.1:8095/health; tail -2 "$HOME/Library/Application Support/tern/plugin-data/overseer/ops.log"`
Expected: `{"ok":true}`; ops.log has `{"op":"server","event":"started"}`. `ls -l …/plugin-data/overseer/token` shows mode `-rw-------`.

- [ ] **Step 4: Check it restarts**

Run: `pkill -f 'bun src/main.ts'; sleep 15; curl -s 127.0.0.1:8095/health`
Expected: `{"ok":true}` again; ops.log has `exited`, then `started`.

- [ ] **Step 5: Commit**

```bash
git add mission.luau window.luau
git commit -m "Mission control: Overseer keeps overseer-server running"
```

---

### Task 3: Connect omp agents

**Files:**
- Modify: `README.md` (setup)
- Outside the repo: `~/.omp/agent/mcp.json`, `~/.omp/agent/AGENTS.md`

- [ ] **Step 1: Add the MCP entry**

```bash
DATA="$HOME/Library/Application Support/tern/plugin-data/overseer"
jq --arg auth "!printf 'Bearer %s' \"\$(cat '$DATA/token')\"" \
  '.mcpServers.overseer = {type: "http", url: "http://127.0.0.1:8095/mcp", headers: {"X-Tern-Pane": "${TERN_PANE}", Authorization: $auth}}' \
  ~/.omp/agent/mcp.json > /tmp/mcp.json && mv /tmp/mcp.json ~/.omp/agent/mcp.json
jq '.mcpServers.overseer' ~/.omp/agent/mcp.json
```

Expected: the entry with `X-Tern-Pane` and an `Authorization` starting with `!printf`.

- [ ] **Step 2: Write the agent note**

```bash
cat > ~/.omp/agent/AGENTS.md <<'EOF'
# Work tracking

When running in Tern with the `overseer` MCP tools: call `task_start` at the start of any task that changes something, `task_note` at real milestones, `ask_user` for any decision you need from the user (also ask in your pane), and `task_done` exactly once at the end. The tool descriptions have the details.
EOF
```

- [ ] **Step 3: Check a real agent reaches the server as itself**

Start a fresh omp in a new tab of your own (`⌘T`, `omp`), ask it: "Call task_start with title 'Connect check', then task_done succeeded 'ok'." Then:

Run: `curl -s -H "Authorization: Bearer $(cat "$HOME/Library/Application Support/tern/plugin-data/overseer/token")" 127.0.0.1:8095/api/thread/T-1 | jq -r '.[].author' | sort -u`
Expected: one omp session id, the same as `$PI_SESSION_ID` in that tab.

- [ ] **Step 4: Document and commit**

Add to README's Install section:

```markdown
**Mission control.** Overseer runs `server/` (Bun, `127.0.0.1:8095`) and keeps it running; data and the access token are in the plugin data directory. Connect omp once:

    DATA="$HOME/Library/Application Support/tern/plugin-data/overseer"
    jq --arg auth "!printf 'Bearer %s' \"\$(cat '$DATA/token')\"" \
      '.mcpServers.overseer = {type: "http", url: "http://127.0.0.1:8095/mcp", headers: {"X-Tern-Pane": "${TERN_PANE}", Authorization: $auth}}' \
      ~/.omp/agent/mcp.json > /tmp/mcp.json && mv /tmp/mcp.json ~/.omp/agent/mcp.json
```

Add [Bun](https://bun.sh) to the requirements table ("Mission control"). Commit:

```bash
git add README.md
git commit -m "README: connect omp to Mission control"
```

---

### Task 4: Deliveries

**Files:**
- Modify: `mission.luau`

Each poll: send the live panes to `/api/panes` to learn which session runs where, fetch `/api/deliveries`, send everything pending for one pane as one prompt, then mark each delivered. A failed send is left pending and retried next poll.

- [ ] **Step 1: Add the bundling helper with its self-check**

```lua
-- Groups deliveries by the pane running their session; drops ones whose session has no pane.
function M.bundle(deliveries, sessionPanes)
	local byPane, order = {}, {}
	for _, d in deliveries do
		local pane = d.session and sessionPanes[d.session]
		if pane then
			if not byPane[pane] then byPane[pane] = {}; table.insert(order, pane) end
			table.insert(byPane[pane], d)
		end
	end
	local out = {}
	for _, pane in order do
		local texts, ids = {}, {}
		for _, d in byPane[pane] do table.insert(texts, d.text); table.insert(ids, d.id) end
		table.insert(out, { pane = pane, text = table.concat(texts, "\n\n---\n\n"), ids = ids })
	end
	return out
end

do
	local b = M.bundle({ { id = 1, session = "a", text = "x" }, { id = 2, session = "b", text = "y" }, { id = 3, session = "a", text = "z" },
		{ id = 4, session = "gone", text = "w" } }, { a = "10", b = "20" })
	assert(#b == 2 and b[1].pane == "10" and b[1].text == "x\n\n---\n\nz" and b[1].ids[2] == 3 and b[2].pane == "20")
end
```

- [ ] **Step 2: Add the delivery pass and poll it from `tick`**

```lua
local function deliver(cx, sessionPanes, done)
	M.api("GET", "/api/deliveries", nil, function(list, err, nextCx)
		if err or not nextCx or type(list) ~= "table" then done(); return end
		for _, bundle in M.bundle(list, sessionPanes) do
			local ok, askErr = pcall(function() nextCx.agents:ask(tonumber(bundle.pane), bundle.text) end)
			if ok then
				for _, id in bundle.ids do M.api("POST", "/api/deliveries/" .. tostring(id) .. "/done", {}, function() end) end
				oplog.write("info", { op = "mission", event = "delivered", detail = "pane " .. bundle.pane .. " (" .. tostring(#bundle.ids) .. ")" })
			else
				warnOnce("ask " .. bundle.pane .. tostring(askErr), "couldn't deliver to pane " .. bundle.pane .. ": " .. tostring(askErr))
			end
		end
		done()
	end)
end

local polling, lastPoll = false, -POLL_MS
M.sessionPanes = {}
```

Extend `M.tick` after the health check:

```lua
	if not healthy or polling or tern.now() - lastPoll < POLL_MS then return end
	polling, lastPoll = true, tern.now()
	M.api("POST", "/api/panes", { panes = panes }, function(map, err, nextCx)
		if err or not nextCx or type(map) ~= "table" then polling = false; return end
		M.sessionPanes = map
		deliver(nextCx, map, function() polling = false end)
	end)
```

(Task 6 chains the worker pass after `deliver`.)

- [ ] **Step 3: Live check**

Reload Overseer. In a fresh omp tab: "Call task_start 'Delivery check', then ask_user 'Proceed?' with options yes/no." Then answer it:

Run: `T=$(cat "$HOME/Library/Application Support/tern/plugin-data/overseer/token"); curl -s -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"task":"T-2","body":"yes, proceed"}' 127.0.0.1:8095/api/answer`
Expected: within ~2 s the agent receives "The user answered on T-2: yes, proceed" as a prompt; ops.log has `mission delivered`.

- [ ] **Step 4: Commit**

```bash
git add mission.luau
git commit -m "Mission control: deliver answers and agents' messages to their panes"
```

---

### Task 5: Goal sessions

**Files:**
- Modify: `mission.luau`, `window.luau`

Starting a goal: the server marks it active and returns the coordinator's brief; Overseer opens a background session named `G-3 · <title>` with omp running that brief, finds the new session's id from `tern ls --json`, and records it on the goal.

- [ ] **Step 1: Check how `tern new tab` addresses a session**

Run: `tern new session zz-addr --cwd /tmp -- /bin/sleep 120; ID=$(tern ls --json | jq -r '.sessions[] | select(.name=="zz-addr") | .id'); tern new tab "$ID" --cwd /tmp -- /bin/sleep 120 && echo by-id-ok`
Expected: `by-id-ok` and the session has two tabs. If it fails, Task 6 passes the session name instead of the id, and the goal records its name (rename-safe enough: Overseer names it). Close it: `for b in $(tern ls --json | jq -r '.sessions[] | select(.name=="zz-addr") | .tabs[].blocks[].id'); do tern close "zz-addr/$b"; done`.

- [ ] **Step 2: Add `startGoal`**

```lua
-- The Tern session holding `pane`, from `tern ls --json` output; nil when absent.
function M.sessionOfPane(lsJson, pane)
	local ok, data = pcall(tern.json.decode, lsJson)
	if not ok or type(data) ~= "table" then return nil end
	for _, session in (data.sessions or {}) do
		for _, tab in (session.tabs or {}) do
			for _, block in (tab.blocks or {}) do
				if tostring(block.id) == pane then return tostring(session.id) end
			end
		end
	end
	return nil
end

do
	local ls = '{"sessions":[{"id":5,"tabs":[{"blocks":[{"id":71},{"id":72}]}]},{"id":6,"tabs":[{"blocks":[{"id":81}]}]}]}'
	assert(M.sessionOfPane(ls, "81") == "6" and M.sessionOfPane(ls, "72") == "5" and M.sessionOfPane(ls, "9") == nil)
end

-- Starts proposed goal `goal` (from /api/state): its own background session, the coordinator in it.
-- `dir` is where the coordinator starts. done(err, pane).
function M.startGoal(goal, dir, done)
	M.api("POST", "/api/goals/" .. goal.ref .. "/start", {}, function(res, err)
		if err or type(res) ~= "table" then done(err or "no brief"); return end
		local name = goal.ref .. " · " .. goal.title
		tern.process.run({ TERN, "new", "session", name, "--cwd", dir, "--", "omp", res.brief }, { timeout_ms = 15000 }, function(r)
			local pane = r.status == 0 and string.match(r.stdout or "", "%d+") or nil
			if not pane then done("couldn't open the goal's session: " .. (r.stderr or "")); return end
			tern.process.run({ TERN, "ls", "--json" }, { timeout_ms = 10000 }, function(l)
				local session = M.sessionOfPane(l.stdout or "", pane) or name
				M.api("POST", "/api/goals/" .. goal.ref .. "/session", { ternSession = session }, function()
					oplog.write("info", { op = "mission", event = "goal started", detail = goal.ref .. " in session " .. session })
					done(nil, pane)
				end)
			end)
		end)
	end)
end
```

- [ ] **Step 3: Palette command (until plan 3's Mission control)**

In `window.luau`, beside the other `tern.command` calls:

```lua
tern.command({ id = "start-goal", title = "Start proposed goal", icon = "branch", run = function(cx)
	mission.api("GET", "/api/state", nil, function(state, err, nextCx)
		if not nextCx then return end
		if err then report(nextCx, "Mission control: " .. err); return end
		local goal
		for _, g in state.goals do if g.status == "proposed" then goal = g; break end end
		if not goal then nextCx:toast("info", "No proposed goals", "Agents propose goals with goal_propose."); return end
		local first
		for _, t in state.tasks do if t.goal == goal.id then first = t; break end end
		local dir = (first and missionHooks.repoPath(first.repo)) or tern.getenv("HOME")
		mission.startGoal(goal, dir, function(startErr)
			if startErr then tern.log.warn("Start goal: " .. startErr) end
		end)
		nextCx:toast("info", "Starting " .. goal.ref, goal.title)
	end)
end })
```

Note: `tern.process.run` callbacks without `cx` can't toast; failures go to Tern's log and ops.log. Plan 3 shows them in Mission control.

- [ ] **Step 4: Live check**

```bash
T=$(cat "$HOME/Library/Application Support/tern/plugin-data/overseer/token")
mkdir -p /tmp/g-a && git -C /tmp/g-a init -q && git -C /tmp/g-a commit -q --allow-empty -m init
```

In a fresh omp tab in `/tmp/g-a`: "Call goal_propose: title 'Goal check', body 'Prove goal sessions', one task key a, title 'Write a.txt', repo g-a." Run **Start proposed goal** from the palette while focused elsewhere.

Run: `tern ls --json | jq -c '.sessions[] | select(.name|startswith("G-")) | {name, shown}'; curl -s -H "Authorization: Bearer $T" 127.0.0.1:8095/api/state | jq -c '.goals[] | {ref, status, coordinator, tern_session}'`
Expected: a session `G-1 · Goal check` with `shown: false`; your focused pane unchanged; the goal `active` with `tern_session` set, and `coordinator` set once the coordinator calls `goal_join` (within a minute).

- [ ] **Step 5: Commit**

```bash
git add mission.luau window.luau
git commit -m "Mission control: goals open in their own background session"
```

---

### Task 6: Workers

**Files:**
- Modify: `mission.luau`

Each poll after deliveries: fetch `/api/workers`; open each requested start as a background tab in its goal's session; close each stop's pane. A writing task's tab runs `wt -C <repo> switch --create <branch> [--base <base>] -x omp -- <brief>`: Worktrunk creates the worktree (hooks run visibly; approvals are answered in that tab), then starts omp there. A read-only task's tab runs omp in the repository's checkout.

- [ ] **Step 1: Add the command builders with self-checks**

```lua
-- Branch for a worker's task: t-12-<title words>, Git-safe, at most 48 characters.
function M.branchFor(task, title)
	local slug = string.gsub(string.lower(title), "[^%w]+", "-")
	slug = string.gsub(string.gsub(slug, "^%-+", ""), "%-+$", "")
	local branch = string.lower(task) .. (if slug ~= "" then "-" .. slug else "")
	return (string.gsub(string.sub(branch, 1, 48), "%-+$", ""))
end

-- argv that opens a worker's tab in its goal's session.
function M.workerArgv(start, repoPath, wtPath, base)
	local argv = { TERN, "new", "tab", start.ternSession, "--cwd", repoPath, "--" }
	if start.readonly then
		table.insert(argv, "omp")
	else
		for _, a in { wtPath, "-C", repoPath, "switch", "--create", M.branchFor(start.task, start.title) } do table.insert(argv, a) end
		if base then table.insert(argv, "--base"); table.insert(argv, base) end
		for _, a in { "-x", "omp", "--" } do table.insert(argv, a) end
	end
	table.insert(argv, start.brief)
	return argv
end

do
	assert(M.branchFor("T-12", "Fix the Tick: stalls!") == "t-12-fix-the-tick-stalls")
	assert(#M.branchFor("T-1", string.rep("word ", 20)) <= 48)
	local s = { task = "T-3", title = "Add API", ternSession = "9", readonly = false, brief = "B" }
	local a = M.workerArgv(s, "/r", "/bin/wt", "main")
	assert(a[4] == "9" and a[8] == "/bin/wt" and a[12] == "t-3-add-api" and a[14] == "main" and a[#a] == "B" and a[#a - 2] == "omp")
	s.readonly = true
	local r = M.workerArgv(s, "/r", "/bin/wt", nil)
	assert(r[8] == "omp" and r[9] == "B")
end
```

- [ ] **Step 2: Add the worker pass and chain it after deliveries**

```lua
local launching = {}

local function workers(hooks, done)
	M.api("GET", "/api/workers", nil, function(list, err)
		if err or type(list) ~= "table" then done(); return end
		for _, start in (list.starts or {}) do
			if not launching[start.id] then
				local repoPath = start.repoPath or hooks.repoPath(start.repo)
				local wtPath = wt.find_executable("wt")
				local reason = (not start.ternSession and "its goal has no session")
					or (not repoPath and ("Overseer doesn't know where " .. tostring(start.repo) .. " is: open it in a space once"))
					or (not start.readonly and not wtPath and "Worktrunk (wt) isn't installed")
				if reason then
					M.api("POST", "/api/workers/" .. tostring(start.id) .. "/failed", { error = reason }, function() end)
				else
					launching[start.id] = true
					tern.process.run(M.workerArgv(start, repoPath, wtPath, hooks.baseFor(start.repo)), { timeout_ms = 15000 }, function(r)
						launching[start.id] = nil
						local pane = r.status == 0 and string.match(r.stdout or "", "%d+") or nil
						if pane then
							M.api("POST", "/api/workers/" .. tostring(start.id) .. "/started", { pane = pane }, function() end)
							oplog.write("info", { op = "mission", event = "worker started", detail = start.task .. " in pane " .. pane })
						else
							M.api("POST", "/api/workers/" .. tostring(start.id) .. "/failed", { error = "tern new tab failed: " .. (r.stderr or "") }, function() end)
						end
					end)
				end
			end
		end
		for _, stop in (list.stops or {}) do
			local function stopped() M.api("POST", "/api/workers/" .. tostring(stop.id) .. "/stopped", {}, function() end) end
			if stop.pane then
				tern.process.run({ TERN, "close", stop.pane }, { timeout_ms = 10000 }, stopped)
			else
				stopped()
			end
		end
		done()
	end)
end
```

In `M.tick`, chain it: `deliver(nextCx, map, function() workers(hooks, function() polling = false end) end)`.

`missionHooks.baseFor` (Task 2) gives the repository's base branch (its Change base branch override, else the detected one); nil lets Worktrunk decide.

- [ ] **Step 3: Live check with a real goal across two repositories**

```bash
mkdir -p /tmp/g-b && git -C /tmp/g-b init -q && git -C /tmp/g-b commit -q --allow-empty -m init
```

Open `/tmp/g-a` and `/tmp/g-b` once each as spaces (so Overseer knows their paths), then in a fresh omp tab: "goal_propose 'Two repo check': task a 'Write a.txt with hello' in g-a; task b 'Write b.txt saying a is done' in g-b, needs a." Run **Start proposed goal**.

Expected, within a few minutes and without your focus moving:
- The goal's session gets a tab `T-…` running `wt … switch --create t-…-write-a-txt…` then omp in the new worktree; `git -C /tmp/g-a worktree list` shows it.
- After it calls `task_done`, the coordinator (via `inbox`) starts the second worker in `/tmp/g-b`'s new worktree.
- `curl …/api/state | jq '.tasks[] | {ref, status}'` ends with both `done`; the coordinator sends you a summary question (`.waiting`).

- [ ] **Step 4: Check stops**

While a worker runs, ask the coordinator to `worker_stop` its task. Expected: its tab closes within ~2 s; the task is `ready` again.

- [ ] **Step 5: Clean up and commit**

Close the goal's session and run `wt remove` on the test worktrees, `rm -rf /tmp/g-a /tmp/g-b`.

```bash
git add mission.luau window.luau
git commit -m "Mission control: workers start in their own worktrees, in the goal's session"
```

---

### Task 7: Docs

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: CHANGELOG** (under 3.0.0 › Changed)

```markdown
- **Mission control server.** Overseer runs `server/` (Bun) on `127.0.0.1:8095` and restarts it if it stops. omp agents connected to it track tasks, ask you questions, message each other and run goals: a coordinator in the goal's own background session starts workers, each in its own worktree. Your answers and agents' messages reach the right agent within seconds. **Start proposed goal** in the palette starts a goal until Mission control (plan 3) shows proposals.
```

- [ ] **Step 2: README "How it works"**: a short paragraph: the server, the token, `X-Tern-Pane` identity, goal sessions never mixing with yours, `server.log` and `ops.log` (`op: server`, `op: mission`) for troubleshooting.

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "Docs: Mission control server, goals and workers"
```

---

## Self-review

- **Spec coverage:** §1 lifecycle (start, health every 5 s, restart after two failures, token in plugin data): Task 2. §2 identity in omp config: Task 3. §5 deliveries with bundling, rate limit (server side) and retry on failure: Task 4. §5/§7 worker starts as background tabs in the goal session, worktrees via Worktrunk, stops: Task 6. §7 goal session per goal, named `G-n · title`, recorded on the goal, focus untouched: Task 5. §6 (block, sidebar Goals, Spaces excluding goal sessions) and **Open worktree** / **Close goal**: plan 3. §8 import from the Huly export: plan 4.
- **Placeholders:** none; repository lookups use `repos` and `repoById` from `window.luau` (lines 32–49).
- **Names:** `mission.api`, `mission.tick(cx, panes, hooks)`, `M.bundle`, `M.sessionOfPane`, `M.startGoal(goal, dir, done)`, `M.branchFor`, `M.workerArgv(start, repoPath, wtPath, base)`, `hooks.repoPath`, `hooks.baseFor`; server: `learnRepo`, `repoPath`, `repoRoot`, `POST /api/panes`, `repoPath` on worker starts.
- **Risk:** `cx.agents:ask` on a worker pane started by `tern new tab` (a terminal running wt, then omp) is untested. The Huly bridge delivered to terminal omp panes this way; if a worker pane refuses, Task 4's warning names it, and the fallback is `tern send <pane> text … && tern send <pane> keys Enter`.
