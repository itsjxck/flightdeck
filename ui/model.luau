-- Mission control's model (host half): talks to overseer-server, groups its
-- state into the block's sections, and lists what the cursor moves over.
-- No drawing (ui/render.luau) and no block wiring (ui/block.luau).
local M = {}

local BASE = "http://127.0.0.1:8095"

local function token()
	local ok, t = pcall(tern.fs.read, tern.plugin.data .. "/token", 256)
	return if ok then string.match(t, "^%s*(.-)%s*$") else nil
end

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

-- What the cursor moves over, in screen order: { kind, item }, kind one of
-- "question", "proposal", "task", "todo". Todo rows count only when shown.
function M.selectable(sections, showTodo)
	local rows = {}
	for _, q in sections.needs do table.insert(rows, { kind = "question", item = q }) end
	for _, g in sections.proposed do table.insert(rows, { kind = "proposal", item = g }) end
	for _, group in sections.working do
		for _, t in group.tasks do table.insert(rows, { kind = "task", item = t }) end
	end
	if showTodo then for _, t in sections.todo do table.insert(rows, { kind = "todo", item = t }) end end
	return rows
end

-- The Backlog tab's groups, from /api/backlog. Pure.
-- goals: newest first, each { goal, tasks } (its coordinator's task left out);
-- loose: tasks outside goals, newest first.
function M.backlog(data)
	local byGoal, goals, loose = {}, {}, {}
	for _, g in data.goals do
		local entry = { goal = g, tasks = {} }
		byGoal[g.id] = entry
		table.insert(goals, entry)
	end
	for _, t in data.tasks do
		local entry = t.goal and byGoal[t.goal]
		if entry then
			if t.session == nil or t.session ~= entry.goal.coordinator then table.insert(entry.tasks, t) end
		else
			table.insert(loose, t)
		end
	end
	return { goals = goals, loose = loose, now = data.now }
end

-- What the cursor moves over in the Backlog tab: goals, the tasks of expanded
-- goals under them, then tasks outside goals. Pure.
function M.backlogRows(backlog, expanded)
	local rows = {}
	for _, entry in backlog.goals do
		table.insert(rows, { kind = "goal", item = entry.goal })
		if expanded[entry.goal.ref] then
			for _, t in entry.tasks do table.insert(rows, { kind = "task", item = t }) end
		end
	end
	for _, t in backlog.loose do table.insert(rows, { kind = "task", item = t }) end
	return rows
end

-- The Repos tab's rows, from /api/repos: each { kind = "repo", item } with item.ref = its name. Pure.
function M.repoRows(data)
	local rows = {}
	for _, r in data.repos do
		table.insert(rows, { kind = "repo", item = { ref = r.name, name = r.name, path = r.path, source = r.source, ignored = r.ignored == 1 } })
	end
	return rows
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
	assert(#M.backlogRows(b, {}) == 3 and #M.backlogRows(b, { ["G-2"] = true }) == 4, "ui.model.backlogRows self-check")
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
	assert(#M.selectable(s, false) == 5 and #M.selectable(s, true) == 6, "ui.model.selectable self-check")
end

return M
