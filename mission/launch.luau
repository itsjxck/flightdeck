-- Opens agent panes in the background and hands them their brief.
--
-- The brief is not passed on omp's command line: an omp started with a
-- prompt begins its first turn before MCP discovery finishes (omp waits only
-- 1.5 s), so it may not see the flightdeck tools at all. Instead the pane opens
-- with plain `omp`, and the brief is sent with cx.agents:ask once Tern has
-- seen an agent in the pane for BRIEF_DELAY_MS. A worker's pane runs
-- Worktrunk first (worktree setup can take minutes), so the clock only starts
-- when omp does. A brief whose pane never gets an agent is dropped after
-- GIVE_UP_MS, with a warning. Waiting briefs are kept in kv (`mission:briefs`)
-- so a plugin reload doesn't lose them (tern.now() runs on across reloads).
--
-- `tern new session|tab` open without moving your focus (checked 2026-11-14).
local client = require("./client")

local M = {}

local BRIEF_DELAY_MS = 8000
local LOST_MS = 10000
-- Pane → what to do if it's lost (not persisted: after a reload a lost pane only times out).
local lostHandlers = {}
local GIVE_UP_MS = 15 * 60 * 1000

-- Briefs waiting for their pane: { pane, brief, at, agentSince }.
local pending = tern.kv.get("mission:briefs")
if type(pending) ~= "table" then pending = {} end
local function save()
	tern.kv.set("mission:briefs", pending)
end

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
	assert(M.sessionOfPane(ls, "81") == "6" and M.sessionOfPane(ls, "72") == "5" and M.sessionOfPane(ls, "9") == nil,
		"launch.sessionOfPane self-check")
end

-- Runs `tern <args…>` (a `new session` or `new tab` command) and queues
-- `brief` for the pane it opens. done(err, pane, cx). `onLost(pane)` runs if
-- the pane turns out to be in no tab (see flush).
function M.open(args, brief, done, onLost)
	local argv = { client.TERN }
	for _, a in args do table.insert(argv, a) end
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = 15000 }, function(result, cx)
		local pane = if result.status == 0 then string.match(result.stdout or "", "%d+") else nil
		if not pane then done("tern " .. tostring(args[1]) .. " " .. tostring(args[2]) .. " failed: " .. (result.stderr or ""), nil, cx); return end
		table.insert(pending, { pane = pane, brief = brief, at = tern.now() })
		if onLost then lostHandlers[pane] = onLost end
		save()
		done(nil, pane, cx)
	end)
	if not ok then done(tostring(err)) end
end

-- Sends briefs whose pane has run an agent for BRIEF_DELAY_MS; call it every tick.
-- A pane still in no tab after LOST_MS is lost: Tern left it out of every tab, so
-- it never becomes an agent. It's closed and its brief dropped (onLost).
function M.flush(cx)
	if #pending == 0 then return end
	local keep, changed = {}, false
	for _, item in pending do
		local inTab = pcall(function() assert(cx.session:tab_of(tonumber(item.pane))) end)
		if not inTab and tern.now() - item.at > LOST_MS and cx.session:pane(tonumber(item.pane)) then
			changed = true
			pcall(function() cx.layout:close(tonumber(item.pane)) end)
			local handler = lostHandlers[item.pane]
			lostHandlers[item.pane] = nil
			if handler then handler(item.pane) end
			client.warnOnce("lost " .. item.pane, "pane " .. item.pane .. " opened in no tab; closed it")
			continue
		end
		local hasAgent = pcall(function() cx.agents:get(tonumber(item.pane)) end)
		if not hasAgent then
			item.agentSince = nil
			if tern.now() - item.at < GIVE_UP_MS then
				table.insert(keep, item)
			else
				changed = true
				client.warnOnce("brief " .. item.pane, "pane " .. item.pane .. " never ran an agent; its brief was dropped")
			end
		else
			item.agentSince = item.agentSince or tern.now()
			if tern.now() - item.agentSince < BRIEF_DELAY_MS then
				table.insert(keep, item)
			else
				changed = true
				local ok, err = pcall(function() cx.agents:ask(tonumber(item.pane), item.brief) end)
				if not ok then client.warnOnce("brief " .. item.pane, "couldn't send the brief to pane " .. item.pane .. ": " .. tostring(err)) end
			end
		end
	end
	pending = keep
	if changed then save() end
end

return M
