-- The last /api/state the poll fetched, for the sidebar. Never blocks: the
-- sidebar draws from whatever is here (empty until the first poll).
local M = {}

local EMPTY = { goals = {}, tasks = {}, waiting = {}, workers = {}, goalSessions = {} }
local current = EMPTY
local signature = ""

-- Stores a fresh state; returns whether it differs from the last one.
function M.set(state)
	if type(state) ~= "table" then return false end
	local sig = tern.json.encode(state)
	if sig == signature then return false end
	current, signature = state, sig
	return true
end

function M.get()
	return current
end

-- The task an omp session is working on (its newest `doing` task), or nil.
function M.taskOf(session)
	local found
	for _, t in current.tasks do
		if t.session == session and t.status == "doing" then found = t end
	end
	return found
end

-- Whether Tern session `id` belongs to a goal.
function M.isGoalSession(id)
	return table.find(current.goalSessions or {}, tostring(id)) ~= nil
end

do
	M.set({ goals = {}, tasks = { { ref = "T-1", session = "s", status = "doing" }, { ref = "T-2", session = "s", status = "done" } },
		waiting = {}, workers = {}, goalSessions = { "9" } })
	assert(M.taskOf("s").ref == "T-1" and M.isGoalSession(9) and not M.isGoalSession(8), "mission.state self-check")
	current, signature = EMPTY, ""
end

return M
