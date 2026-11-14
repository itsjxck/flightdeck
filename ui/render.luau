-- Mission control's view (host half). Pure: model in, nodes out. Built from
-- Tern's own components (stats, cards, tables, sections, empty states) in the
-- sans face, so it looks like the rest of Tern. The reply field sits in the
-- block's dock, below the scrolling main area.
local ui = tern.ui
local Input = require("../input")

local M = {}

-- How an agent is doing on a task, as a table cell with a status dot.
-- `agent`: "working" | "waiting" | "idle" | nil (no live agent).
local AGENT = {
	working = { text = "Working", dot = "success" },
	waiting = { text = "Waiting for you", dot = "accent" },
	idle = { text = "Idle", dot = "muted" },
}
local STATUS = { ready = "Ready to start", todo = "Waiting on others", done = "Done", failed = "Failed", dropped = "Dropped" }

local function stateCell(t, agentOf)
	if t.status == "doing" then
		local a = AGENT[agentOf(t.session)]
		if a then return { text = a.text, dot = a.dot } end
		return { text = "No agent", dot = "warning", title = "The agent working on this task isn't running" }
	end
	return { text = STATUS[t.status] or t.status, dot = if t.status == "done" then "success" elseif t.status == "failed" then "error" else "muted" }
end

-- Sets props (key, …) on a node a ui builder returned ({k, p, c}).
local function keyed(node, props)
	node.p = node.p or {}
	for k, v in props do node.p[k] = v end
	return node
end

local function muted(key, text)
	return ui.node("text", { key = key, text = text, role = "overseer.hint" })
end

local function oneLine(s)
	return if s then (string.gsub(s, "%s+", " ")) else ""
end

local TASK_COLS = {
	{ id = "ref", head = "Task", mono = true },
	{ id = "title", head = "Title", grow = 2, truncate = "end" },
	{ id = "state", head = "State" },
	{ id = "repo", head = "Repository", priority = -1, mono = true },
	{ id = "note", head = "Latest", grow = 3, priority = -2, truncate = "end" },
}

local function taskTable(key, tasks, selected, agentOf, empty)
	local rows = {}
	for _, t in tasks do
		table.insert(rows, { id = t.ref, cells = {
			t.ref, t.title, stateCell(t, agentOf), t.repo or "", oneLine(t.lastNote),
		}, title = t.title })
	end
	return keyed(ui.table(TASK_COLS, rows, { selectable = true, selected = selected, empty = empty or "Nothing here" }), { key = key })
end

-- A question waiting on you, as a card: the question, then its options as buttons.
local function questionCard(q, picked)
	local buttons = {}
	for i, option in (q.options or {}) do
		table.insert(buttons, ui.button(tostring(i) .. "  " .. option, {
			key = "o" .. i, variant = if q.recommended == i then "primary" else "default",
			title = if q.recommended == i then "Recommended" else nil,
			actions = { click = "answer=" .. q.task .. "=" .. tostring(i) },
		}))
	end
	local body = { ui.md(q.question) }
	if #buttons > 0 then table.insert(body, ui.node("row", { key = "options", role = "mission.options" }, buttons)) end
	return keyed(ui.card({ q.task .. " · " .. q.title }, body, { icon = "bell", meta = { q.repo or "" } }), {
		key = "q" .. q.task, mark = if picked then "pick" else nil, actions = { click = "select=" .. q.task },
	})
end

-- The whole block. `view`: { sections, selectedRef, showTodo, thread, reply, replyTo, replyHint, error, agentOf }.
-- Returns the block's { main, dock }.
function M.view(view)
	local s = view.sections
	local agentOf = view.agentOf or function() return nil end
	local main = {}
	if view.error then table.insert(main, ui.node("text", { key = "error", text = view.error, role = "overseer.error" })) end

	local working = 0
	for _, g in s.working do working += #g.tasks end
	table.insert(main, keyed(ui.stats({
		{ label = "Needs you", value = tostring(#s.needs), tone = if #s.needs > 0 then "accent" else nil },
		{ label = "Proposed goals", value = tostring(#s.proposed) },
		{ label = "In progress", value = tostring(working) },
		{ label = "Todo", value = tostring(#s.todo) },
	}), { key = "stats" }))

	-- Needs you
	local needs = {}
	for _, q in s.needs do table.insert(needs, questionCard(q, q.task == view.selectedRef)) end
	if #needs == 0 then
		table.insert(needs, muted("none", "Nothing needs you. Questions agents ask with ask_user show up here."))
	end
	table.insert(main, keyed(ui.section({ "Needs you" }, needs), { key = "s-needs" }))

	-- Proposed goals
	if #s.proposed > 0 then
		local rows = {}
		for _, g in s.proposed do
			table.insert(rows, { id = g.ref, cells = { g.ref, g.title, { button = { text = "Start", act = "start" } } } })
		end
		table.insert(main, keyed(ui.section({ "Proposed goals" }, {
			keyed(ui.table({ { id = "ref", head = "Goal", mono = true }, { id = "title", head = "Title", grow = 1 }, { id = "start", head = "" } },
				rows, { selectable = true, selected = view.selectedRef }), { key = "proposed" }),
		}), { key = "s-proposed" }))
	end

	-- Working, a card per goal
	local groups = {}
	for _, group in s.working do
		local g = group.goal
		local head = if g then { g.ref .. " · " .. g.title } else { "Not part of a goal" }
		local meta = if g and g.progress then { tostring(g.progress.done) .. " of " .. tostring(g.progress.total) .. " done" } else { "" }
		table.insert(groups, keyed(ui.card(head, { taskTable("w" .. (if g then g.ref else "none"), group.tasks, view.selectedRef, agentOf) },
			{ icon = if g then "target" else "list", meta = meta }), { key = "g" .. (if g then g.ref else "none") }))
	end
	if #groups == 0 then
		table.insert(groups, muted("idle", "No tasks in progress. Agents start tasks with task_start; goals run in sessions of their own."))
	end
	table.insert(main, keyed(ui.section({ "In progress" }, groups), { key = "s-working" }))

	-- Todo
	table.insert(main, keyed(ui.section({ "Todo" }, if view.showTodo
		then { taskTable("todo", s.todo, view.selectedRef, agentOf, "No tasks for later") }
		else { muted("todo-hint", tostring(#s.todo) .. " for later · press t to show") }), { key = "s-todo" }))

	-- Thread of the selected task
	if view.thread then
		local events = {}
		for _, e in view.thread.events do
			local who = if e.author == "you" then "You" elseif e.author == "overseer" then "Overseer" else "Agent"
			table.insert(events, keyed(ui.card({ who }, { ui.md(e.body) }, { meta = { e.kind } }), { key = "e" .. tostring(e.id) }))
		end
		if #events == 0 then table.insert(events, muted("none", "No notes yet.")) end
		table.insert(main, keyed(ui.section({ view.thread.task .. " thread · Esc closes" }, events), { key = "s-thread" }))
	end

	-- Dock: the reply field, and what the keys do.
	local dock = {}
	if view.replyTo then
		local props = Input.props(view.reply)
		props.key, props.role, props.grow = "reply", "overseer.field", 1
		props.placeholder = view.replyHint or ("Reply to " .. view.replyTo .. ", Enter sends")
		table.insert(dock, ui.node("input", props))
	end
	table.insert(dock, ui.node("text", { key = "keys", role = "overseer.hint",
		text = "↑↓ select · 1–9 answer · Enter go to agent / start · o thread · r review · t todo · n new task" }))

	return ui.node("scroll", { key = "main", role = "mission.main" }, main), ui.node("col", { key = "dock", role = "mission.dock" }, dock)
end

do
	local sections = { needs = { { task = "T-1", title = "t", question = "Q?", options = { "a", "b" }, recommended = 1 } },
		proposed = {}, working = { { goal = nil, tasks = { { ref = "T-2", title = "x", status = "doing", session = "s" } } } }, todo = {} }
	local main, dock = M.view({ sections = sections, selectedRef = "T-1", showTodo = false, reply = Input.new(""), replyTo = "T-1",
		agentOf = function() return "working" end })
	assert(main ~= nil and dock ~= nil, "ui.render.view self-check")
end

return M
