-- Mission control's view (host half). Pure: model in, nodes out; the look
-- lives in styles.css (roles `mission.*`).
--
-- Layout, top to bottom: a header with one live sentence; "Your turn"
-- (questions, large, options as numbered keys); goals, each with a rail of
-- one segment per task coloured by state; other work; proposed goals; todo.
-- Every task is a strip whose left edge carries its state colour, so state
-- reads at a glance down the page. The reply field and key hints sit in the
-- block's dock.
local ui = tern.ui
local Input = require("../input")

local M = {}

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

-- Children lists may hold nils (optional parts, `if x then node else nil`);
-- this keeps every node, in slot order.
local function compact(children)
	local slots = {}
	for i in children do table.insert(slots, i) end
	table.sort(slots)
	local out = {}
	for _, i in slots do table.insert(out, children[i]) end
	return out
end

local function row(key, role, children, props)
	props = props or {}
	props.key, props.role = key, role
	return ui.node("row", props, compact(children))
end

local function col(key, role, children, props)
	props = props or {}
	props.key, props.role = key, role
	return ui.node("col", props, compact(children))
end

local function plural(n, one, many)
	return tostring(n) .. " " .. (if n == 1 then one else many)
end

-- "just now", "4 min ago", "2 h ago", "3 d ago". Pure.
function M.ago(now, at)
	if not now or not at then return nil end
	local s = math.max(0, (now - at) / 1000)
	if s < 60 then return "just now" end
	if s < 3600 then return tostring(math.floor(s / 60)) .. " min ago" end
	if s < 86400 then return tostring(math.floor(s / 3600)) .. " h ago" end
	return tostring(math.floor(s / 86400)) .. " d ago"
end

-- A task's state: a key (its colour in styles.css) and a label.
-- `agent`: "working" | "waiting" | "idle" | nil (no live agent). Pure.
function M.taskState(t, agent, waiting)
	if waiting then return "waiting", "Your turn" end
	if t.status == "done" then return "done", "Done" end
	if t.status == "failed" then return "failed", "Failed" end
	if t.status == "dropped" then return "pending", "Dropped" end
	if t.status == "doing" then
		if agent == "working" then return "working", "Working" end
		if agent == "waiting" then return "waiting", "Waiting for you" end
		if agent == "idle" then return "idle", "Idle" end
		return "lost", "No agent"
	end
	if t.status == "ready" then return "pending", "Ready to start" end
	return "pending", "Waiting on others"
end

-- A note on one line, without Markdown emphasis and code marks. Pure.
function M.oneLine(s)
	if not s then return nil end
	return (string.gsub(string.gsub(s, "[*_`]+", ""), "%s+", " "))
end
local oneLine = M.oneLine

-- The header's sentence: what's going on, most urgent first.
local function summary(s, agentOf)
	local working = 0
	for _, g in s.working do
		for _, t in g.tasks do if t.status == "doing" and agentOf(t.session) == "working" then working += 1 end end
	end
	local goals = 0
	for _, g in s.working do if g.goal then goals += 1 end end
	local parts = {}
	if #s.needs > 0 then table.insert(parts, plural(#s.needs, "question waits for you", "questions wait for you")) end
	table.insert(parts, if working > 0 then plural(working, "agent working", "agents working") else "no agent working")
	if goals > 0 then table.insert(parts, plural(goals, "goal running", "goals running")) end
	if #s.proposed > 0 then table.insert(parts, plural(#s.proposed, "goal to start", "goals to start")) end
	return table.concat(parts, " · ")
end

-- A question waiting on you.
local function questionNode(q, picked, now)
	local options = {}
	for i, option in (q.options or {}) do
		local recommended = q.recommended == i
		table.insert(options, row("o" .. i, if recommended then "mission.optionBest" else "mission.option", {
			text("key", tostring(i), "mission.keycap"),
			text("label", option, "mission.optionLabel"),
			if recommended then text("best", "recommended", "mission.optionNote") else nil,
		}, { actions = { click = "answer=" .. q.task .. "=" .. tostring(i) },
			title = "Answer “" .. option .. "” (" .. tostring(i) .. ")" }))
	end
	local eyebrow = { q.task, q.repo, q.goal, M.ago(now, q.asked) }
	local shown = {}
	for i = 1, 4 do if eyebrow[i] then table.insert(shown, eyebrow[i]) end end
	local children = {
		text("eyebrow", table.concat(shown, " · "), "mission.eyebrow"),
		text("task", q.title, "mission.questionTask"),
		col("question", "mission.questionText", { ui.md(q.question) }),
	}
	if #options > 0 then table.insert(children, row("options", "mission.options", options)) end
	table.insert(children, text("how", if #options > 0 then "Press a number, or type your own answer below"
		else "Type your answer below and press Enter", "mission.hint"))
	return col("q" .. q.task, if picked then "mission.questionPicked" else "mission.question", children,
		{ actions = { click = "select=" .. q.task }, mark = if picked then "pick" else nil })
end

-- A task as a strip: state edge, ref, title and latest note, where, state.
local function strip(t, picked, agentOf, waitingTasks)
	local key, label = M.taskState(t, agentOf(t.session), waitingTasks[t.ref])
	local where = t.repo or ""
	if t.branch then where = where .. (if where ~= "" then " · " else "") .. t.branch end
	local note = oneLine(t.lastNote)
	return row("t" .. t.ref, "mission.strip-" .. key, {
		text("ref", t.ref, "mission.ref"),
		col("main", "mission.stripMain", {
			text("title", t.title, "mission.stripTitle"),
			if note then text("note", note, "mission.stripNote") else nil,
		}, { grow = 1 }),
		text("where", where, "mission.where"),
		row("state", "mission.state", {
			ui.el("div", { key = "dot", role = "mission.dot-" .. key }),
			text("label", label, "mission.stateLabel"),
		}),
	}, { actions = { click = "select=" .. t.ref }, title = t.title, mark = if picked then "pick" else nil })
end

-- The rail: one segment per task, in order, coloured by state.
local function rail(tasks, agentOf, waitingTasks)
	local segments = {}
	for _, t in tasks do
		local key, label = M.taskState(t, agentOf(t.session), waitingTasks[t.ref])
		table.insert(segments, ui.el("div", { key = "s" .. t.ref, role = "mission.seg-" .. key, title = t.ref .. " · " .. label }))
	end
	return row("rail", "mission.rail", segments)
end

local function panel(key, head, body, role)
	return col(key, role or "mission.panel", { head, col("body", "mission.panelBody", body) })
end

local function sectionHead(key, title, note)
	return row(key, "mission.sectionHead", {
		text("title", title, "mission.sectionTitle"),
		if note then text("note", note, "mission.sectionNote") else nil,
	})
end

-- The whole block. `view`: { sections, selectedRef, showTodo, thread, reply, replyTo, replyHint, error, agentOf }.
-- Returns the block's main and dock nodes.
function M.view(view)
	local s = view.sections
	local agentOf = view.agentOf or function() return nil end
	local waitingTasks = {}
	for _, q in s.needs do waitingTasks[q.task] = true end
	local main = {}

	table.insert(main, col("header", "mission.header", {
		text("title", "Mission control", "mission.title"),
		text("summary", summary(s, agentOf), "mission.summary"),
	}))
	if view.error then table.insert(main, text("error", view.error, "mission.notice")) end

	-- Your turn
	if #s.needs > 0 then
		local cards = {}
		for _, q in s.needs do table.insert(cards, questionNode(q, q.task == view.selectedRef, s.now)) end
		table.insert(main, col("needs", "mission.section", {
			sectionHead("head", "Your turn", plural(#s.needs, "question", "questions")),
			col("cards", "mission.questions", cards),
		}))
	else
		table.insert(main, row("clear", "mission.allClear", {
			ui.el("div", { key = "dot", role = "mission.dot-done" }),
			text("text", "Nothing needs you. Questions from agents show up here.", "mission.allClearText"),
		}))
	end

	-- Goals, then work outside goals
	local goalPanels, loose = {}, nil
	for _, group in s.working do
		local g = group.goal
		local strips = {}
		for _, t in group.tasks do table.insert(strips, strip(t, t.ref == view.selectedRef, agentOf, waitingTasks)) end
		if g then
			local progress = if g.progress then tostring(g.progress.done) .. " of " .. tostring(g.progress.total) .. " done" else ""
			table.insert(goalPanels, panel("g" .. g.ref, col("head", "mission.goalHead", {
				row("line", "mission.goalLine", {
					text("ref", g.ref, "mission.ref"),
					text("title", g.title, "mission.goalTitle", { grow = 1 }),
					if group.coordinator then (function()
						local key, label = M.taskState(group.coordinator, agentOf(group.coordinator.session), waitingTasks[group.coordinator.ref])
						return row("coord", "mission.coordinator", {
							ui.el("div", { key = "dot", role = "mission.dot-" .. key }),
							text("label", "Coordinator " .. string.lower(label), "mission.stateLabel"),
						}, { title = group.coordinator.ref .. " · " .. (oneLine(group.coordinator.lastNote) or group.coordinator.title) })
					end)() else nil,
					text("progress", progress, "mission.goalProgress"),
					ui.el("button", { key = "open", role = "mission.quiet", text = "Open session",
						actions = { click = "session=" .. g.ref } }),
				}),
				rail(group.tasks, agentOf, waitingTasks),
			}), strips))
		else
			loose = strips
		end
	end
	if #goalPanels > 0 then
		table.insert(main, col("goals", "mission.section", { sectionHead("head", "Goals", plural(#goalPanels, "running", "running")), col("list", "mission.panels", goalPanels) }))
	end
	if loose then
		table.insert(main, col("loose", "mission.section", {
			sectionHead("head", if #goalPanels > 0 then "Other work" else "Work in progress", plural(#loose, "task", "tasks")),
			col("list", "mission.strips", loose),
		}))
	elseif #goalPanels == 0 then
		table.insert(main, col("idle", "mission.section", {
			sectionHead("head", "Work in progress", nil),
			text("empty", "No agent is on a task. Agents call task_start when they begin; goals you start run in sessions of their own.", "mission.empty"),
		}))
	end

	-- Proposed goals
	if #s.proposed > 0 then
		local cards = {}
		for _, g in s.proposed do
			table.insert(cards, row("p" .. g.ref, if g.ref == view.selectedRef then "mission.proposalPicked" else "mission.proposal", {
				text("ref", g.ref, "mission.ref"),
				col("text", "mission.stripMain", {
					text("title", g.title, "mission.stripTitle"),
					if g.body and g.body ~= "" then text("body", oneLine(g.body), "mission.stripNote") else nil,
				}, { grow = 1 }),
				ui.button("Start goal", { key = "start", variant = "primary", actions = { click = "start=" .. g.ref } }),
			}, { actions = { click = "select=" .. g.ref } }))
		end
		table.insert(main, col("proposed", "mission.section", {
			sectionHead("head", "Proposed by agents", "starting one opens its own session"),
			col("list", "mission.strips", cards),
		}))
	end

	-- Todo
	local todo = {}
	if view.showTodo then
		for _, t in s.todo do table.insert(todo, strip(t, t.ref == view.selectedRef, agentOf, waitingTasks)) end
		if #todo == 0 then table.insert(todo, text("empty", "Nothing for later. Press n to add a task.", "mission.empty")) end
	end
	table.insert(main, col("todo", "mission.section", {
		sectionHead("head", "For later", plural(#s.todo, "task", "tasks") .. (if view.showTodo then " · t hides" else " · t shows")),
		if view.showTodo then col("list", "mission.strips", todo) else nil,
	}))

	-- Thread
	if view.thread then
		local events = {}
		for _, e in view.thread.events do
			local who = if e.author == "you" then "You" elseif e.author == "overseer" then "Overseer" else "Agent"
			table.insert(events, col("e" .. tostring(e.id), "mission.event-" .. (if e.author == "you" then "you" else "agent"), {
				text("who", who .. " · " .. e.kind .. (if M.ago(s.now, e.created) then " · " .. M.ago(s.now, e.created) else ""), "mission.eyebrow"),
				ui.md(e.body),
			}))
		end
		if #events == 0 then table.insert(events, text("none", "No notes yet.", "mission.empty")) end
		table.insert(main, col("thread", "mission.section", {
			sectionHead("head", view.thread.task .. " thread", "Esc closes"),
			col("events", "mission.thread", events),
		}))
	end

	local dock = {}
	if view.replyTo then
		local props = Input.props(view.reply)
		props.key, props.role, props.grow = "reply", "mission.reply", 1
		props.placeholder = view.replyHint or ("Answer " .. view.replyTo .. " and press Enter")
		table.insert(dock, row("replyRow", "mission.replyRow", { text("to", view.replyTo, "mission.replyTo"), ui.node("input", props) }))
	end
	table.insert(dock, text("keys", "↑↓ move   1–9 answer   Enter go to agent   o thread   r review   t later   n new task", "mission.keys"))

	return ui.node("scroll", { key = "main", role = "mission.main" }, main), col("dock", "mission.dock", dock)
end

do
	assert(M.oneLine("**Done**: `a`\n b") == "Done: a b", "ui.render.oneLine self-check")
	assert(M.ago(120000, 0) == "2 min ago" and M.ago(1000, 0) == "just now" and M.ago(nil, 0) == nil, "ui.render.ago self-check")
	assert(M.taskState({ status = "doing" }, nil) == "lost" and M.taskState({ status = "doing" }, "working") == "working"
		and M.taskState({ status = "todo" }, nil, true) == "waiting", "ui.render.taskState self-check")
	local sections = { now = 0, needs = { { task = "T-1", title = "t", question = "Q?", options = { "a", "b" }, recommended = 1 } },
		proposed = { { ref = "G-2", title = "p" } },
		working = { { goal = { ref = "G-1", title = "g", progress = { done = 0, total = 1 } }, tasks = { { ref = "T-2", title = "x", status = "doing", session = "s" } } } },
		todo = {} }
	local main, dock = M.view({ sections = sections, selectedRef = "T-1", showTodo = true, reply = Input.new(""), replyTo = "T-1",
		agentOf = function() return "working" end })
	assert(main ~= nil and dock ~= nil, "ui.render.view self-check")
end

return M
