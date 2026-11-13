-- The Huly bridge. Every POLL_MS it runs huly/bridge.cjs (Huly's own JS
-- client, which Luau can't speak) with the window's live agent states. The
-- helper keeps each linked issue's Agent state in step with Tern and returns
-- the issues linked to live panes plus your comments not yet delivered. Those
-- go to their agent with cx.agents:ask; `huly-seen` in kv records the newest
-- comment delivered per issue, so a failed delivery is retried next poll and
-- nothing is sent twice.
local oplog = require("./oplog")

local M = {}

local POLL_MS = 30000
-- Node 25+ has a global sessionStorage, which sends Huly's client down its browser path.
local HELPER = "NODE_OPTIONS=--no-experimental-webstorage npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/bridge.cjs'"

-- Linked issues by pane id (a string): { id, ident, title, url }.
M.tasks = {}

local running = false
local lastPoll = -POLL_MS
local warned = {}

local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	tern.log.warn("Overseer Huly bridge: " .. message)
end

local function deliver(cx, comments, seen)
	-- One prompt per issue, its comments oldest first.
	local byIssue, order = {}, {}
	for _, comment in comments do
		if not byIssue[comment.id] then byIssue[comment.id] = {}; table.insert(order, comment.id) end
		table.insert(byIssue[comment.id], comment)
	end
	for _, id in order do
		local list = byIssue[id]
		table.sort(list, function(a, b) return a.createdOn < b.createdOn end)
		local first, parts, newest = list[1], {}, 0
		for _, comment in list do
			table.insert(parts, comment.text)
			newest = math.max(newest, comment.createdOn)
		end
		local message = "New comment" .. (if #list > 1 then "s" else "") .. " from the user on " .. first.ident
			.. " (" .. first.title .. ") in Huly:\n\n" .. table.concat(parts, "\n\n---\n\n")
			.. "\n\nAct on it, and reply with a comment on " .. first.ident .. " as the huly-tasks skill says."
		local ok, err = pcall(function() cx.agents:ask(tonumber(first.pane), message) end)
		if ok then
			seen[id] = newest
			oplog.write("info", { op = "huly", event = "delivered", detail = first.ident .. " → pane " .. first.pane .. " (" .. tostring(#list) .. ")" })
		else
			-- Left unrecorded, so the next poll tries again (another prompt may be pending).
			warnOnce("ask " .. id .. tostring(err), "couldn't deliver " .. first.ident .. ": " .. tostring(err))
		end
	end
end

-- Whether the bridge runs: off until turned on with **Turn Huly bridge on or off**,
-- since it needs a local Huly (kv `huly`).
function M.enabled()
	return tern.kv.get("huly") == true
end

-- Turns the bridge on or off. Off drops the issue links from agent rows at once.
function M.setEnabled(on)
	tern.kv.set("huly", on)
	if on then lastPoll = -POLL_MS else M.tasks = {} end
end

-- Starts a poll when one is due. `agents` is { [pane id string] = "working" | "waiting" | "idle" };
-- `redraw(cx)` runs when the linked issues change.
function M.poll(agents, redraw)
	if not M.enabled() or running or tern.now() - lastPoll < POLL_MS then return end
	running, lastPoll = true, tern.now()
	local seen = tern.kv.get("huly-seen") or {}
	local input = tern.json.encode({ panes = agents, seen = seen })
	local ok, err = pcall(tern.process.run, { "/bin/zsh", "-lc", HELPER }, { cwd = ".", stdin = input, timeout_ms = 60000 }, function(result, cx)
		running = false
		if result.status ~= 0 then
			warnOnce("helper " .. tostring(result.status), "helper failed (" .. tostring(result.status) .. "): " .. string.sub(result.stderr or "", -300))
			return
		end
		local decoded, out = pcall(tern.json.decode, result.stdout)
		if not decoded or type(out) ~= "table" then warnOnce("decode", "unreadable helper output"); return end
		local seenNow = tern.kv.get("huly-seen") or {}
		for id, newest in (out.seen or {}) do
			if seenNow[id] == nil then seenNow[id] = newest end
		end
		if cx and type(out.comments) == "table" and #out.comments > 0 then deliver(cx, out.comments, seenNow) end
		tern.kv.set("huly-seen", seenNow)
		local tasks = {}
		for _, item in (out.tasks or {}) do
			tasks[item.pane] = { id = item.id, ident = item.ident, title = item.title, url = item.url }
		end
		local changed = tern.json.encode(tasks) ~= tern.json.encode(M.tasks)
		M.tasks = tasks
		if changed and cx then redraw(cx) end
	end)
	if not ok then running = false; warnOnce("spawn", tostring(err)) end
end

-- Whether `url` is a page of the local Huly (the sidebar's issue links).
function M.ownsUrl(url)
	return type(url) == "string" and string.sub(url, 1, #"http://localhost:8087/") == "http://localhost:8087/"
end

return M
