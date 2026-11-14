-- Starts and stops the workers coordinators request (worker_start /
-- worker_stop). A worker opens as a background tab in its goal's session.
-- A writing task's tab runs Worktrunk, which creates the task's worktree
-- (setup hooks run there, visibly; approval prompts are answered in that tab)
-- and then starts omp in it. A read-only task's tab runs omp in the
-- repository's checkout. launch.luau sends the brief once omp is up.
local client = require("./client")
local launch = require("./launch")
local oplog = require("../oplog")
local wt = require("../worktrunk")

local M = {}

-- Branch for a worker's task: t-12-<title words>, Git-safe, at most 48 characters.
function M.branchFor(task, title)
	local slug = string.gsub(string.lower(title), "[^%w]+", "-")
	slug = string.gsub(string.gsub(slug, "^%-+", ""), "%-+$", "")
	local branch = string.lower(task) .. (if slug ~= "" then "-" .. slug else "")
	return (string.gsub(string.sub(branch, 1, 48), "%-+$", ""))
end

-- `tern` arguments that open a worker's tab (see launch.open).
-- `start`: a worker start from /api/workers; `base`: branch to create from, or nil for Worktrunk's default.
function M.tabArgs(start, repoPath, wtPath, base)
	local args = { "new", "tab", start.ternSession, "--cwd", repoPath, "--" }
	if start.readonly then
		table.insert(args, "omp")
		return args
	end
	for _, a in { wtPath, "-C", repoPath, "switch", "--create", M.branchFor(start.task, start.title) } do table.insert(args, a) end
	if base then table.insert(args, "--base"); table.insert(args, base) end
	table.insert(args, "-x")
	table.insert(args, "omp")
	return args
end

do
	assert(M.branchFor("T-12", "Fix the Tick: stalls!") == "t-12-fix-the-tick-stalls", "workers.branchFor self-check")
	assert(#M.branchFor("T-1", string.rep("word ", 20)) <= 48, "workers.branchFor length self-check")
	local s = { task = "T-3", title = "Add API", ternSession = "9", readonly = false }
	local a = M.tabArgs(s, "/r", "/bin/wt", "main")
	assert(a[3] == "9" and a[7] == "/bin/wt" and a[12] == "t-3-add-api" and a[14] == "main" and a[#a] == "omp", "workers.tabArgs self-check")
	s.readonly = true
	local r = M.tabArgs(s, "/r", "/bin/wt", nil)
	assert(r[7] == "omp" and #r == 7, "workers.tabArgs read-only self-check")
end

-- Worker ids being opened right now, so a slow `tern new tab` isn't started twice.
local launching = {}

local function fail(id, reason)
	client.post("/api/workers/" .. tostring(id) .. "/failed", { error = reason })
	oplog.write("warn", { op = "mission", event = "worker failed", detail = "W-" .. tostring(id) .. ": " .. reason })
end

local function startOne(start, hooks)
	local repoPath = start.repoPath or hooks.repoPath(start.repo)
	local wtPath = wt.find_executable("wt")
	if not start.ternSession then fail(start.id, "its goal has no session"); return end
	if not repoPath then fail(start.id, "Overseer doesn't know where " .. tostring(start.repo) .. " is: open it in a space once"); return end
	if not start.readonly and not wtPath then fail(start.id, "Worktrunk (wt) isn't installed"); return end
	launching[start.id] = true
	launch.open(M.tabArgs(start, repoPath, wtPath, hooks.baseFor(start.repo)), start.brief, function(err, pane)
		launching[start.id] = nil
		if err then fail(start.id, err); return end
		client.post("/api/workers/" .. tostring(start.id) .. "/started", { pane = pane })
		oplog.write("info", { op = "mission", event = "worker started", detail = start.task .. " in pane " .. pane })
	end)
end

-- One worker pass: opens requested workers, closes stopping ones. done() runs when it's finished.
-- `hooks`: repoPath(name), baseFor(name) (missionHooks in window.luau).
function M.run(hooks, done)
	client.api("GET", "/api/workers", nil, function(list, err)
		if err or type(list) ~= "table" then done(); return end
		for _, start in (list.starts or {}) do
			if not launching[start.id] then startOne(start, hooks) end
		end
		for _, stop in (list.stops or {}) do
			local function stopped() client.post("/api/workers/" .. tostring(stop.id) .. "/stopped", {}) end
			if stop.pane then tern.process.run({ client.TERN, "close", stop.pane }, { timeout_ms = 10000 }, stopped) else stopped() end
		end
		done()
	end)
end

return M
