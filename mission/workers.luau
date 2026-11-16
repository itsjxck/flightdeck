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

-- Branch for a worker's task: g3.2-<title words>, Git-safe, at most BRANCH_MAX characters.
local BRANCH_MAX = 28
function M.branchFor(task, title)
	local slug = string.gsub(string.lower(title), "[^%w]+", "-")
	slug = string.gsub(string.gsub(slug, "^%-+", ""), "%-+$", "")
	local branch = string.lower(task) .. (if slug ~= "" then "-" .. slug else "")
	-- Short: omp's footer shows the branch, and a long one pushes the rest (ponytail's status) out of view.
	return (string.gsub(string.sub(branch, 1, BRANCH_MAX), "%-+$", ""))
end

-- `tern` arguments that open a worker's tab (see launch.open).
-- `start`: a worker start from /api/workers; `base`: branch to create from, or nil for Worktrunk's default.
function M.tabArgs(start, repoPath, wtPath, base)
	local args = { "new", "tab", start.ternSession, "--cwd", repoPath, "--" }
	if start.readonly then
		table.insert(args, "omp")
		return args
	end
	-- A reopened task's branch exists already (start.existing): switch to it.
	if start.existing then
		for _, a in { wtPath, "-C", repoPath, "switch", start.branch or M.branchFor(start.task, start.title) } do table.insert(args, a) end
	else
		for _, a in { wtPath, "-C", repoPath, "switch", "--create", M.branchFor(start.task, start.title) } do table.insert(args, a) end
		if base then table.insert(args, "--base"); table.insert(args, base) end
	end
	table.insert(args, "-x")
	table.insert(args, "omp")
	return args
end

-- Whether a branch is one branchFor made for a goal's worker: g3.2-… (or t-12-…
-- from before goal-numbered tasks). Spaces leaves those worktrees out.
function M.isWorkerBranch(branch)
	return type(branch) == "string" and (string.match(branch, "^g%d+%.%d+") ~= nil or string.match(branch, "^t%-%d+%-") ~= nil)
end

do
	assert(M.isWorkerBranch("g1.3-db-secrets") and M.isWorkerBranch("t-5-db-land") and not M.isWorkerBranch("main")
		and not M.isWorkerBranch("feat/g1.3") and not M.isWorkerBranch(nil), "workers.isWorkerBranch self-check")
	assert(M.branchFor("T-12", "Fix the Tick: stalls!") == "t-12-fix-the-tick-stalls", "workers.branchFor self-check")
	assert(#M.branchFor("G1.5", string.rep("word ", 20)) <= BRANCH_MAX, "workers.branchFor length self-check")
	local s = { task = "T-3", title = "Add API", ternSession = "9", readonly = false }
	local a = M.tabArgs(s, "/r", "/bin/wt", "main")
	assert(a[3] == "9" and a[7] == "/bin/wt" and a[12] == "t-3-add-api" and a[14] == "main" and a[#a] == "omp", "workers.tabArgs self-check")
	s.existing = true
	local e = M.tabArgs(s, "/r", "/bin/wt", "main")
	assert(e[11] == "t-3-add-api" and e[12] == "-x", "workers.tabArgs existing-branch self-check")
	s.existing, s.readonly = nil, true
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
	if not repoPath then fail(start.id, "Flightdeck doesn't know where " .. tostring(start.repo) .. " is: open it in a space once"); return end
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
-- Removes the worktrees the server queued (a coordinator's worktree_remove, or
-- the user's Close goal): `wt remove` with the branch (-D: squash merges look
-- unmerged to Git) and --yes, since no one is there to approve hooks. A
-- worktree already gone counts as removed. The result goes back to the server,
-- which tells the coordinator.
local removing = {}
local function removeQueued(list)
	local wtPath = wt.find_executable("wt")
	for _, c in list do
		if not removing[c.id] and c.repoPath and wtPath then
			removing[c.id] = true
			local function done(ok, detail)
				removing[c.id] = nil
				client.post("/api/cleanups/" .. tostring(c.id), if ok then {} else { error = detail or "wt remove failed" })
				oplog.write(if ok then "info" else "warn", { op = "mission", event = if ok then "worktree removed" else "worktree removal failed",
					detail = c.worktree .. (if detail then ": " .. detail else "") })
			end
			if not tern.fs.exists(c.worktree) then done(true, "already gone")
			else
				tern.process.run({ wtPath, "-C", c.repoPath, "remove", "--yes", "-D", c.branch }, { timeout_ms = 120000 }, function(r)
					done(r.status == 0, if r.status ~= 0 then (r.stderr or ""):sub(1, 200) else nil)
				end)
			end
		end
	end
end

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
		client.api("GET", "/api/cleanups", nil, function(c)
			if type(c) == "table" and c.cleanups then removeQueued(c.cleanups) end
		end)
		done()
	end)
end

return M
