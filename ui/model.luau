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
		local inActiveGoal = goal ~= nil and goal.status == "active"
		if t.status == "doing" or (inActiveGoal and t.status ~= "dropped") then
			local key = t.goal or 0
			if not groups[key] then groups[key] = { goal = goal, tasks = {} }; table.insert(order, key) end
			table.insert(groups[key].tasks, t)
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

do
	local s = M.sections({
		goals = { { id = 1, ref = "G-1", title = "g", status = "active" }, { id = 2, ref = "G-2", title = "p", status = "proposed" } },
		waiting = { { task = "T-2" } },
		tasks = { { ref = "T-1", goal = 1, status = "doing" }, { ref = "T-2", status = "doing" }, { ref = "T-3", status = "todo" },
			{ ref = "T-4", goal = 2, status = "ready" }, { ref = "T-5", goal = 1, status = "done" } },
	})
	assert(#s.needs == 1 and #s.proposed == 1 and #s.working == 2 and s.working[1].goal.ref == "G-1"
		and #s.working[1].tasks == 2 and #s.todo == 1, "ui.model.sections self-check")
	assert(#M.selectable(s, false) == 5 and #M.selectable(s, true) == 6, "ui.model.selectable self-check")
end

return M
