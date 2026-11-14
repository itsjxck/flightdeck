-- Starts goals. Each goal runs in a Tern session of its own, named
-- `G-3 · <title>`, apart from your sessions; its coordinator is the first tab.
local client = require("./client")
local launch = require("./launch")
local oplog = require("../oplog")

local M = {}

-- Starts proposed goal `goal` (a goal from /api/state): marks it active, opens
-- its session with the coordinator in `dir`, records the session on the goal.
-- done(err, pane, cx); cx may be nil.
function M.start(goal, dir, done)
	client.api("POST", "/api/goals/" .. goal.ref .. "/start", {}, function(res, err, cx)
		if err or type(res) ~= "table" then done(err or "the server returned no brief", nil, cx); return end
		local name = goal.ref .. " · " .. goal.title
		launch.open({ "new", "session", name, "--cwd", dir, "--", "omp" }, res.brief, function(openErr, pane, openCx)
			if openErr then done("couldn't open the goal's session: " .. openErr, nil, openCx); return end
			tern.process.run({ client.TERN, "ls", "--json" }, { timeout_ms = 10000 }, function(ls, lsCx)
				local session = launch.sessionOfPane(ls.stdout or "", pane) or name
				client.post("/api/goals/" .. goal.ref .. "/session", { ternSession = session })
				oplog.write("info", { op = "mission", event = "goal started", detail = goal.ref .. " in session " .. session })
				done(nil, pane, lsCx)
			end)
		end)
	end)
end

-- Starts the oldest proposed goal, in its first task's repository (else ~).
-- `repoPath(name)` finds a repository's folder. done(err, goal, cx); goal is nil when none is proposed.
function M.startOldestProposed(repoPath, done)
	client.api("GET", "/api/state", nil, function(state, err, cx)
		if err or type(state) ~= "table" then done(err or "no state", nil, cx); return end
		local goal
		for _, g in state.goals do
			if g.status == "proposed" then goal = g; break end
		end
		if not goal then done(nil, nil, cx); return end
		local dir
		for _, t in state.tasks do
			if t.goal == goal.id then dir = t.repoPath or repoPath(t.repo); break end
		end
		M.start(goal, dir or tern.getenv("HOME") or "/", function(startErr, _, startCx) done(startErr, goal, startCx) end)
	end)
end

return M
