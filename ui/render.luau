-- Mission control's view (host half). Pure: model in, nodes out. Rows the
-- cursor can select are counted in the same order as model.selectable, so
-- `selected` (1-based) marks the matching row.
local ui = tern.ui
local Input = require("../input")

local M = {}

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function header(key, title, count, hint)
	local children = { text("title", title, "overseer.heading", { grow = 1 }) }
	if hint then table.insert(children, text("hint", hint, "overseer.hint")) end
	if count then table.insert(children, text("count", tostring(count), "overseer.count")) end
	return ui.node("row", { key = key, role = "overseer.header" }, children)
end

local STATUS = { doing = "working", ready = "ready to start", todo = "waiting on others", done = "done", failed = "failed" }

-- A question waiting on you: where it's from, the question, its options.
local function questionNode(q, picked)
	local options = {}
	for i, option in (q.options or {}) do
		table.insert(options, ui.el("button", {
			key = "o" .. i, role = if q.recommended == i then "overseer.primaryButton" else "overseer.button",
			text = tostring(i) .. ". " .. option .. (if q.recommended == i then " (recommended)" else ""),
			actions = { click = "answer=" .. q.task .. "=" .. tostring(i) },
		}))
	end
	local children = {
		text("from", q.task .. " · " .. q.title .. (if q.repo then " · " .. q.repo else ""), "overseer.hint"),
		ui.md(q.question),
	}
	if #options > 0 then table.insert(children, ui.node("row", { key = "options", role = "overseer.formButtons" }, options)) end
	return ui.node("col", { key = "q" .. q.task, role = "mission.card", mark = if picked then "pick" else nil,
		actions = { click = "select=" .. q.task } }, children)
end

local function taskRow(t, picked)
	return ui.node("row", { key = "t" .. t.ref, role = "mission.row", mark = if picked then "pick" else nil,
		actions = { click = "select=" .. t.ref } }, {
		text("ref", t.ref, "mission.ref"),
		ui.node("col", { key = "body", grow = 1 }, {
			text("title", t.title, "overseer.spaceName"),
			text("meta", (STATUS[t.status] or t.status) .. (if t.repo then " · " .. t.repo else "")
				.. (if t.lastNote then " · " .. (string.gsub(t.lastNote, "%s+", " ")) else ""), "overseer.hint"),
		}),
	})
end

-- A task's thread: every event, oldest first.
local function threadNode(thread)
	local items = { header("th", thread.task .. " thread", nil, "Esc closes") }
	for _, e in thread.events do
		local who = if e.author == "you" then "You" elseif e.author == "overseer" then "Overseer" else "Agent"
		table.insert(items, ui.node("col", { key = "e" .. tostring(e.id), role = "mission.event" }, {
			text("who", who .. " · " .. e.kind, "overseer.hint"), ui.md(e.body),
		}))
	end
	return ui.node("col", { key = "thread", role = "mission.thread" }, items)
end

-- The whole block. `view`: { sections, selected, showTodo, thread, reply (Input field), replyTo, error }.
function M.view(view)
	local s = view.sections
	local rows, index = {}, 0
	local function picked() index += 1; return index == view.selected end
	if view.error then table.insert(rows, text("error", view.error, "overseer.error")) end

	table.insert(rows, header("h-needs", "Needs you", #s.needs, "1–9 answers · type to reply"))
	for _, q in s.needs do table.insert(rows, questionNode(q, picked())) end
	if #s.needs == 0 then table.insert(rows, text("none", "Nothing needs you.", "overseer.hint")) end

	if #s.proposed > 0 then
		table.insert(rows, header("h-proposed", "Proposed goals", #s.proposed, "Enter starts"))
		for _, g in s.proposed do
			table.insert(rows, ui.node("row", { key = "p" .. g.ref, role = "mission.row", mark = if picked() then "pick" else nil }, {
				text("ref", g.ref, "mission.ref"),
				text("title", g.title, "overseer.spaceName", { grow = 1 }),
				ui.el("button", { key = "start", text = "Start", role = "overseer.primaryButton", actions = { click = "start=" .. g.ref } }),
			}))
		end
	end

	table.insert(rows, header("h-working", "Working", nil, "Enter goes to the agent · o thread · r review"))
	for _, group in s.working do
		local g = group.goal
		table.insert(rows, text("g" .. (if g then g.ref else "none"),
			if g then g.ref .. " · " .. g.title .. (if g.progress then " · " .. g.progress.done .. "/" .. g.progress.total .. " done" else "")
			else "No goal", "mission.group"))
		for _, t in group.tasks do table.insert(rows, taskRow(t, picked())) end
	end
	if #s.working == 0 then table.insert(rows, text("idle", "No agent is working on a task.", "overseer.hint")) end

	table.insert(rows, header("h-todo", "Todo", #s.todo, if view.showTodo then "t hides · n adds" else "t shows · n adds"))
	if view.showTodo then for _, t in s.todo do table.insert(rows, taskRow(t, picked())) end end

	local main = ui.node("scroll", { key = "main", grow = 1 }, rows)
	local foot = {}
	if view.replyTo then
		local props = Input.props(view.reply)
		props.key, props.role, props.placeholder = "reply", "overseer.field", view.replyHint or ("Reply to " .. view.replyTo .. "…")
		props.grow = 1
		foot = { ui.node("row", { key = "foot", role = "mission.foot" }, { text("to", view.replyTo, "mission.ref"), ui.node("input", props) }) }
	end
	local body = { main }
	if view.thread then body = { main, ui.node("scroll", { key = "side", grow = 1 }, { threadNode(view.thread) }) } end
	local content = ui.node("row", { key = "body", grow = 1 }, body)
	local children = { content }
	for _, f in foot do table.insert(children, f) end
	return ui.node("col", { key = "mission", role = "mission.root" }, children)
end

do
	local sections = { needs = { { task = "T-1", title = "t", question = "Q?", options = { "a", "b" }, recommended = 1 } },
		proposed = {}, working = {}, todo = {} }
	assert(M.view({ sections = sections, selected = 1, showTodo = false, reply = Input.new(""), replyTo = "T-1" }) ~= nil,
		"ui.render.view self-check")
end

return M
