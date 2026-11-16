-- Mission control's model (host half): talks to flightdeck-server, groups its
-- state into the block's sections, and lists what the cursor moves over.
-- No drawing (ui/render.luau) and no block wiring (ui/block.luau).
local M = {}

local BASE = "http://127.0.0.1:" .. (tonumber(tern.getenv("FLIGHTDECK_PORT") or "") or 8095)
M.BASE = BASE

local function token()
	local ok, t = pcall(tern.fs.read, tern.plugin.data .. "/token", 256)
	return if ok then string.match(t, "^%s*(.-)%s*$") else nil
end

M.token = function() return token() end

-- Calls the server's JSON API. fn(body, err).
function M.api(method, path, body, fn)
	local t = token()
	if not t then fn(nil, "Mission control's server isn't running yet"); return end
	tern.fetch(BASE .. path, {
		method = method, timeout_ms = 10000,
		headers = { Authorization = "Bearer " .. t, ["Content-Type"] = "application/json" },
		body = if body ~= nil then tern.json.encode(body) else nil,
	}, function(r)
		if r.error then fn(nil, r.error); return end
		local ok, v = pcall(tern.json.decode, r.body)
		if r.status ~= 200 then
			fn(nil, if ok and type(v) == "table" and v.error then v.error else "HTTP " .. tostring(r.status))
			return
		end
		fn(if ok then v else nil, nil)
	end)
end

-- Asks the window half to act (it can open sessions and focus panes; the host can't).
-- See missionRequests in window.luau.
function M.request(r)
	local list = tern.kv.get("mission:requests")
	if type(list) ~= "table" then list = {} end
	table.insert(list, r)
	tern.kv.set("mission:requests", list)
end

-- Groups server state into the block's sections. Pure.
-- needs: questions waiting on you; proposed: goals to start; working: tasks in
-- progress or ready, grouped by goal (goal nil = no goal); todo: tasks for later.
function M.sections(state)
	local goalsById = {}
	for _, g in state.goals do goalsById[g.id] = g end
	local proposed, todo, working = {}, {}, {}
	for _, g in state.goals do if g.status == "proposed" then table.insert(proposed, g) end end
	local groups, order = {}, {}
	for _, t in state.tasks do
		local goal = t.goal and goalsById[t.goal]
		local inActiveGoal = goal ~= nil and (goal.status == "active" or goal.status == "finished")
		if t.status == "doing" or (inActiveGoal and t.status ~= "dropped") then
			local key = t.goal or 0
			if not groups[key] then groups[key] = { goal = goal, tasks = {} }; table.insert(order, key) end
			-- The coordinator's own task ("Coordinate …") is the goal's, not one of its tasks.
			if goal and goal.coordinator ~= nil and t.session == goal.coordinator then groups[key].coordinator = t
			else table.insert(groups[key].tasks, t) end
		elseif t.status == "todo" or t.status == "ready" then
			if not (goal and goal.status == "proposed") then table.insert(todo, t) end
		end
	end
	for _, key in order do table.insert(working, groups[key]) end
	return { needs = state.waiting, proposed = proposed, working = working, todo = todo, now = state.now }
end

-- What the cursor moves over in the Now tab, in screen order: { kind, item },
-- kind "question" or "task". Proposed goals and tasks for later live in Backlog.
function M.selectable(sections)
	local rows = {}
	for _, q in sections.needs do table.insert(rows, { kind = "question", item = q }) end
	for _, group in sections.working do
		for _, t in group.tasks do table.insert(rows, { kind = "task", item = t }) end
	end
	return rows
end

-- Whether any of `tasks` (or `extra`, a goal's coordinator task) is in `repo`.
local function touches(tasks, repo, extra)
	if extra and extra.repo == repo then return true end
	for _, t in tasks do if t.repo == repo then return true end end
	return false
end

-- The Now tab narrowed to one repository (nil: everything). A goal stays when
-- any of its tasks is in the repository, with all its tasks. Pure.
function M.filterSections(sections, repo)
	if not repo then return sections end
	local needs, working = {}, {}
	for _, q in sections.needs do if q.repo == repo then table.insert(needs, q) end end
	for _, group in sections.working do
		if group.goal then
			if touches(group.tasks, repo, group.coordinator) then table.insert(working, group) end
		else
			local tasks = {}
			for _, t in group.tasks do if t.repo == repo then table.insert(tasks, t) end end
			if #tasks > 0 then table.insert(working, { goal = nil, tasks = tasks }) end
		end
	end
	return { needs = needs, working = working, proposed = sections.proposed, todo = sections.todo, now = sections.now }
end





-- The Repos tab's rows, from /api/repos: each { kind = "repo", item } with item.ref = its name. Pure.
function M.repoRows(data)
	local rows = {}
	for _, r in data.repos do
		table.insert(rows, { kind = "repo", item = { ref = r.name, name = r.name, path = r.path, source = r.source,
			ignored = r.ignored == 1, issuesIgnored = r.issues_ignored == 1 } })
	end
	return rows
end

-- Goals and tasks stop being "open" once closed (goals: done, dropped) or
-- finished (tasks outside goals: done, failed, dropped). The Backlog shows
-- those finished today in their own section and hides older ones unless asked.
local CLOSED_GOAL = { done = true, dropped = true }
local FINISHED_TASK = { done = true, failed = true, dropped = true }

-- The Backlog tab's groups, from /api/backlog. Pure. Each list is newest first:
-- goals (open, each { goal, tasks, coordinator }), loose (open tasks outside goals),
-- todayGoals / todayTasks (closed since local midnight), earlierGoals / earlierTasks.
function M.backlog(data)
	local byGoal = {}
	local b = { goals = {}, loose = {}, todayGoals = {}, todayTasks = {}, earlierGoals = {}, earlierTasks = {},
		now = data.now, todayStart = data.todayStart or 0 }
	for _, g in data.goals do
		local entry = { goal = g, tasks = {} }
		byGoal[g.id] = entry
		local list = if not CLOSED_GOAL[g.status] then b.goals
			elseif (g.closed or g.created or 0) >= b.todayStart then b.todayGoals else b.earlierGoals
		table.insert(list, entry)
	end
	for _, t in data.tasks do
		local entry = t.goal and byGoal[t.goal]
		if entry then
			if t.session == nil or t.session ~= entry.goal.coordinator then table.insert(entry.tasks, t) else entry.coordinator = t end
		else
			local list = if not FINISHED_TASK[t.status] then b.loose
				elseif (t.updated or 0) >= b.todayStart then b.todayTasks else b.earlierTasks
			table.insert(list, t)
		end
	end
	return b
end

-- What the cursor moves over in the Backlog tab, in screen order: open goals (with
-- the tasks of expanded ones), open tasks, then today's and (showDone) earlier finished ones. Pure.
function M.backlogRows(backlog, expanded, showDone)
	local rows = {}
	local function goals(list)
		for _, entry in list do
			table.insert(rows, { kind = "goal", item = entry.goal })
			if expanded[entry.goal.ref] then
				for _, t in entry.tasks do table.insert(rows, { kind = "task", item = t }) end
			end
		end
	end
	local function tasks(list) for _, t in list do table.insert(rows, { kind = "task", item = t }) end end
	goals(backlog.goals); tasks(backlog.loose)
	goals(backlog.todayGoals); tasks(backlog.todayTasks)
	if showDone then goals(backlog.earlierGoals); tasks(backlog.earlierTasks) end
	return rows
end

-- The Backlog narrowed to one repository (nil: everything). Pure.
function M.filterBacklog(backlog, repo)
	if not repo or not backlog then return backlog end
	local out = { now = backlog.now, todayStart = backlog.todayStart }
	for _, key in { "goals", "todayGoals", "earlierGoals" } do
		out[key] = {}
		for _, entry in backlog[key] do if touches(entry.tasks, repo) then table.insert(out[key], entry) end end
	end
	for _, key in { "loose", "todayTasks", "earlierTasks" } do
		out[key] = {}
		for _, t in backlog[key] do if t.repo == repo then table.insert(out[key], t) end end
	end
	return out
end

-- The repositories goals, tasks and open issues are in, by name, for the filter. Pure.
function M.repoChoices(backlog, issues)
	local seen, names = {}, {}
	local function add(name) if name and not seen[name] then seen[name] = true; table.insert(names, name) end end
	if backlog then
		for _, key in { "goals", "todayGoals", "earlierGoals" } do
			for _, entry in backlog[key] do for _, t in entry.tasks do add(t.repo) end end
		end
		for _, key in { "loose", "todayTasks", "earlierTasks" } do for _, t in backlog[key] do add(t.repo) end end
	end
	for _, i in (issues or {}) do add(i["local"]) end
	table.sort(names)
	return names
end

-- The Issues tab's rows from /api/issues, narrowed to the repository filter:
-- { kind = "issue", item } with item.ref = "owner/repo#12". Pure.
function M.issueRows(data, repo)
	local rows = {}
	for _, i in (data and data.issues or {}) do
		if not repo or i["local"] == repo then
			i.ref = i.repo .. "#" .. tostring(i.number)
			table.insert(rows, { kind = "issue", item = i })
		end
	end
	return rows
end

do
	local rows = M.issueRows({ issues = { { repo = "o/a", ["local"] = "a", number = 1 }, { repo = "o/b", ["local"] = "b", number = 2 } } }, "b")
	assert(#rows == 1 and rows[1].item.ref == "o/b#2", "ui.model.issueRows self-check")
end

do
	assert(M.repoRows({ repos = { { name = "a", path = "/a", source = "scanned", ignored = 1 } } })[1].item.ignored == true,
		"ui.model.repoRows self-check")
end

do
	local b = M.backlog({ now = 0,
		goals = { { id = 2, ref = "G-2", coordinator = "c" }, { id = 1, ref = "G-1" } },
		tasks = { { ref = "T-3", goal = 2, session = "c" }, { ref = "T-2", goal = 2 }, { ref = "T-1" } } })
	assert(#b.goals == 2 and #b.goals[1].tasks == 1 and #b.loose == 1, "ui.model.backlog self-check")
	local d = M.backlog({ now = 0, todayStart = 100, goals = { { id = 1, ref = "G-1", status = "done", closed = 150 }, { id = 2, ref = "G-2", status = "dropped", closed = 50 } },
		tasks = { { ref = "T-1", status = "done", updated = 120 }, { ref = "T-2", status = "failed", updated = 10 }, { ref = "T-3", status = "ready", updated = 10 } } })
	assert(#d.todayGoals == 1 and #d.earlierGoals == 1 and #d.todayTasks == 1 and #d.earlierTasks == 1 and #d.loose == 1
		and #M.backlogRows(d, {}, false) == 3 and #M.backlogRows(d, {}, true) == 5, "ui.model.backlog done-aging self-check")
	assert(#M.backlogRows(b, {}) == 3 and #M.backlogRows(b, { ["G-2"] = true }) == 4, "ui.model.backlogRows self-check")
	b.goals[1].tasks[1].repo, b.loose[1].repo = "web", "api"
	assert(table.concat(M.repoChoices(b), ",") == "api,web" and #M.filterBacklog(b, "web").goals == 1
		and #M.filterBacklog(b, "web").loose == 0, "ui.model.repoChoices/filterBacklog self-check")
end

do
	local s = M.sections({
		goals = { { id = 1, ref = "G-1", title = "g", status = "active", coordinator = "c" }, { id = 2, ref = "G-2", title = "p", status = "proposed" } },
		waiting = { { task = "T-2" } },
		tasks = { { ref = "T-1", goal = 1, status = "doing" }, { ref = "T-2", status = "doing" }, { ref = "T-3", status = "todo" },
			{ ref = "T-6", goal = 1, status = "doing", session = "c" },
			{ ref = "T-4", goal = 2, status = "ready" }, { ref = "T-5", goal = 1, status = "done" } },
	})
	assert(#s.needs == 1 and #s.proposed == 1 and #s.working == 2 and s.working[1].goal.ref == "G-1"
		and #s.working[1].tasks == 2 and s.working[1].coordinator.ref == "T-6" and #s.todo == 1, "ui.model.sections self-check")
	assert(#M.selectable(s) == 4, "ui.model.selectable self-check")
	local f = M.filterSections({ needs = { { repo = "a" }, { repo = "b" } },
		working = { { goal = { ref = "G-1" }, tasks = { { repo = "b" }, { repo = "a" } } }, { tasks = { { repo = "a" }, { repo = "b" } } } } }, "a")
	assert(#f.needs == 1 and #f.working == 2 and #f.working[1].tasks == 2 and #f.working[2].tasks == 1, "ui.model.filterSections self-check")
end

return M
