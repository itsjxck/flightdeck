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

-- Refs of the dependencies not yet done ({ ref, status } list → { "G2.1", … }). Pure.
function M.openRefs(list)
	local out = {}
	for _, d in (list or {}) do
		if d.status ~= "done" and d.status ~= "dropped" then table.insert(out, d.ref) end
	end
	return out
end

-- "G2.1", "G2.1, G2.3", "G2.1, G2.3 +2". Pure.
function M.refList(refs)
	if #refs <= 2 then return table.concat(refs, ", ") end
	return refs[1] .. ", " .. refs[2] .. " +" .. tostring(#refs - 2)
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
	if t.goal == nil then return "pending", "For later" end
	local on = M.openRefs(t.needs)
	if #on > 0 then return "pending", "Waiting on " .. M.refList(on) end
	return "pending", "Waiting on others"
end

-- A note on one line, without Markdown emphasis and code marks. Pure.
function M.oneLine(s)
	if not s then return nil end
	-- Emphasis marks only: underscores inside words (apple_pay) stay.
	return (string.gsub(string.gsub(string.gsub(s, "[*`]+", ""), "%f[%w]__?(.-)__?%f[%W]", "%1"), "%s+", " "))
end
local oneLine = M.oneLine

-- The header's sentence: what's going on, most urgent first.
local function summary(s, agentOf)
	local working = 0
	for _, g in s.working do
		for _, t in g.tasks do if t.status == "doing" and agentOf(t.session) == "working" then working += 1 end end
	end
	local goals, finished = 0, 0
	for _, g in s.working do
		if g.goal and g.goal.status == "finished" then finished += 1 elseif g.goal then goals += 1 end
	end
	local parts = {}
	if #s.needs > 0 then table.insert(parts, plural(#s.needs, "question waits for you", "questions wait for you")) end
	table.insert(parts, if working > 0 then plural(working, "agent working", "agents working") else "no agent working")
	if goals > 0 then table.insert(parts, plural(goals, "goal running", "goals running")) end
	if finished > 0 then table.insert(parts, plural(finished, "goal to review", "goals to review")) end
	if #s.proposed > 0 then table.insert(parts, plural(#s.proposed, "goal to start in Backlog", "goals to start in Backlog")) end
	return table.concat(parts, " · ")
end

-- A question waiting on you.
-- `reply`: the answer field's props when this card is the selected one.
local function questionNode(q, picked, now, reply)
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
	if reply then
		table.insert(children, ui.node("input", reply))
	else
		table.insert(children, text("how", "Click to answer", "mission.hint"))
	end
	return col("q" .. q.task, if picked then "mission.questionPicked" else "mission.question", children,
		{ actions = { click = "select=q:" .. q.task }, mark = if picked then "pick" else nil })
end

-- Which items show their details (refs → true); set by M.view for the whole render.
local openItems = {}
local openThreadRef = nil
local goalDetail

-- Details under an item: Markdown, then label/value lines, then buttons ({ label, action, primary }).
local function detail(key, markdown, facts, buttons)
	local children = {}
	if markdown and string.find(markdown, "%S") then table.insert(children, col("md", "mission.detailMd", { ui.md(markdown) })) end
	local lines = {}
	for n, f in facts do
		if f[2] and f[2] ~= "" then
			table.insert(lines, row("f" .. tostring(n), "mission.fact", {
				text("k", f[1], "mission.factKey"),
				text("v", f[2], if f[3] then "mission.factLink" else "mission.factValue", if f[3] then { actions = { click = f[3] } } else nil),
			}))
		end
	end
	if #lines > 0 then table.insert(children, col("facts", "mission.facts", lines)) end
	local bs = {}
	for n, b in buttons do
		if b then table.insert(bs, ui.button(b[1], { key = "b" .. tostring(n), variant = if b[3] then "primary" else "default", actions = { click = b[2] } })) end
	end
	if #bs > 0 then table.insert(children, row("buttons", "mission.detailButtons", bs)) end
	return col(key, "mission.detail", children)
end

local TASK_STATUS = { todo = "Waiting on other tasks", ready = "Ready to start", doing = "In progress", done = "Done", failed = "Failed", dropped = "Dropped" }

-- "G2.1 (in progress), G2.3 (done)". Pure.
local function depText(list)
	if not list or #list == 0 then return nil end
	local parts = {}
	for _, d in list do table.insert(parts, d.ref .. " (" .. (TASK_STATUS[d.status] or d.status) .. ")") end
	return table.concat(parts, ", ")
end


local function taskDetail(t)
	-- The latest note in full, under the task's description.
	local md = t.body or ""
	if t.lastNote then md = md .. (if md ~= "" then "\n\n" else "") .. "**Latest note:** " .. t.lastNote end
	return detail("detail", md, {
		{ "Status", TASK_STATUS[t.status] or t.status },
		{ "Waits on", depText(t.needs) },
		{ "Holds up", depText(t.blocks) },
		{ "Repository", t.repo },
		{ "Branch", t.branch },
		{ "Worktree", t.worktree and (string.gsub(t.worktree, "^/Users/[^/]+", "~")) },
		{ "PR", t.pr, t.pr and ("url=" .. t.pr) },
	}, {
		if t.session and t.status == "doing" then { "Go to agent", "go=" .. t.ref, true } else false,
		{ if openThreadRef == t.ref then "Hide thread" else "Thread", "thread=" .. t.ref },
		if t.worktree then { "Review changes", "review=" .. t.ref } else false,
	})
end

-- A task as a strip: state edge, ref, title and latest note, where, state. Click shows its details.
local function strip(t, picked, agentOf, waitingTasks)
	local key, label = M.taskState(t, agentOf(t.session), waitingTasks[t.ref])
	local where = t.repo or ""
	if t.branch then where = where .. (if where ~= "" then " · " else "") .. t.branch end
	local note = oneLine(t.lastNote)
	-- What it holds up, while it isn't finished: the tasks waiting on it.
	local holds = if t.status ~= "done" and t.status ~= "dropped" then M.openRefs(t.blocks) else {}
	local line = row("line", "mission.strip-" .. key, {
		text("ref", t.ref, "mission.ref"),
		col("main", "mission.stripMain", {
			-- The title line carries what the task holds up, so the right-hand columns keep their room.
			row("head", "mission.stripHead", {
				text("title", t.title, "mission.stripTitle"),
				if #holds > 0 then text("holds", "holding up " .. M.refList(holds), "mission.holdsUp",
					{ title = table.concat(holds, ", ") .. " wait on " .. t.ref }) else nil,
			}),
			if note then text("note", note, "mission.stripNote") else nil,
		}, { grow = 1 }),
		text("where", where, "mission.where", { title = where }),
		row("state", "mission.state", {
			ui.el("div", { key = "dot", role = "mission.dot-" .. key }),
			text("label", label, "mission.stateLabel"),
		}),
	}, { actions = { click = "toggle=" .. t.ref }, title = t.title, mark = if picked then "pick" else nil })
	return col("t" .. t.ref, "mission.item", { line, if openItems[t.ref] then taskDetail(t) else nil })
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

-- A task's thread: every event, oldest first.
local function threadSection(thread, now)
	local events = {}
	for _, e in thread.events do
		local who = if e.author == "you" then "You" elseif e.author == "flightdeck" then "Flightdeck" else "Agent"
		table.insert(events, col("e" .. tostring(e.id), "mission.event-" .. (if e.author == "you" then "you" else "agent"), {
			text("who", who .. " · " .. e.kind .. (if M.ago(now, e.created) then " · " .. M.ago(now, e.created) else ""), "mission.eyebrow"),
			ui.md(e.body),
		}))
	end
	if #events == 0 then table.insert(events, text("none", "No notes yet.", "mission.empty")) end
	return col("thread", "mission.section", {
		sectionHead("head", thread.task .. " thread", "Esc closes"),
		col("events", "mission.thread", events),
	})
end

-- The dock: the reply field when something takes text, then what the keys do.
local function dockNode(view, keys)
	local dock = {}
	if view.replyTo and not view.replyInCard then
		local props = Input.props(view.reply)
		props.key, props.role, props.grow = "reply", "mission.reply", 1
		props.placeholder = view.replyHint or ("Answer " .. view.replyTo .. " and press Enter")
		table.insert(dock, row("replyRow", "mission.replyRow", { text("to", view.replyTo, "mission.replyTo"), ui.node("input", props) }))
	end
	table.insert(dock, text("keys", keys, "mission.keys"))
	return col("dock", "mission.dock", dock)
end

-- Mission control's tabs, in order: id and label.
M.TABS = { { id = "now", label = "Now" }, { id = "backlog", label = "Backlog" }, { id = "issues", label = "Issues" },
	{ id = "stats", label = "Stats" }, { id = "repos", label = "Repos" } }

local function tabStrip(current, needs)
	local tabs = {}
	for _, t in M.TABS do
		local label = t.label .. (if t.id == "now" and needs > 0 then " · " .. tostring(needs) else "")
		-- A row, not a button element: Tern's button chrome can't be fully restyled.
		table.insert(tabs, row(t.id, if t.id == current then "mission.tabOn" else "mission.tab",
			{ text("label", label, "mission.tabLabel") },
			{ actions = { click = "tab=" .. t.id }, aria = t.label .. " tab" .. (if t.id == current then ", selected" else "") }))
	end
	return row("tabs", "mission.tabs", tabs)
end

-- The repository filter, a dropdown (Tern has no native select): a trigger
-- showing the choice, and when open a menu of "All repos" then each repository
-- goals and tasks are in. `hover` is the menu item the keyboard is on.
local function filterBar(choices, current, open, hover)
	if #choices == 0 then return nil end
	local items = {}
	if open then
		for i, name in { "*", table.unpack(choices) } do
			local picked = (name == "*" and current == nil) or name == current
			table.insert(items, row("i" .. tostring(i), if i == hover then "mission.menuItemOn" else "mission.menuItem", {
				text("check", if picked then "✓" else "", "mission.menuCheck"),
				text("label", if name == "*" then "All repos" else name, "mission.menuLabel"),
			}, { actions = { click = "filter=" .. name } }))
		end
	end
	return col("filter", "mission.filter", {
		row("trigger", if open then "mission.selectOpen" else "mission.select", {
			text("what", "Repo", "mission.selectWhat"),
			text("value", current or "All repos", "mission.selectValue"),
			text("chev", "▾", "mission.selectChev"),
		}, { actions = { click = "filtermenu" }, title = "Filter by repository (f)" }),
		if open then col("menu", "mission.menu", items) else nil,
	})
end

-- A goal's linked issues as small links (click opens the issue).
local function issueLinks(issues)
	if not issues or #issues == 0 then return nil end
	local links = {}
	for n, i in issues do
		table.insert(links, text("i" .. tostring(n), i.repo .. "#" .. tostring(i.number), "mission.issueLink",
			{ actions = { click = "url=" .. i.url }, title = i.title }))
	end
	return row("issues", "mission.issueLinks", links)
end

-- An ISO 8601 time (GitHub's) as milliseconds since 1970; nil when it isn't one. Pure.
function M.isoMs(iso)
	local y, mo, d, h, mi, s = string.match(iso or "", "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return nil end
	-- Days from the civil date (Howard Hinnant's algorithm), so no os.time/time zone is involved.
	y, mo = tonumber(y) - (if tonumber(mo) <= 2 then 1 else 0), tonumber(mo)
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * (mo + (if mo > 2 then -3 else 9)) + 2) / 5) + tonumber(d) - 1
	local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
	return ((days * 24 + tonumber(h)) * 60 + tonumber(mi)) * 60000 + tonumber(s) * 1000
end

-- The Issues tab: open GitHub issues of your repositories, newest activity first.
local function issueNodes(view)
	local data = view.issues
	if not data then return { text("loading", "Fetching issues with gh…", "mission.empty") } end
	local rows = {}
	for _, r in view.issueRows do
		local i = r.item
		local marked = view.marked[i.ref] == true
		local labels = {}
		for n, l in i.labels do if n <= 3 then table.insert(labels, text("l" .. tostring(n), l, "mission.label")) end end
		local line = row("line", "mission.issue", {
			text("mark", if marked then "■" else "□", if marked then "mission.markOn" else "mission.mark",
				{ actions = { click = "mark=" .. i.ref }, title = "Mark (space) to make one goal from several issues" }),
			text("ref", i.repo .. "#" .. tostring(i.number), "mission.issueRef"),
			text("title", i.title, "mission.stripTitle", { grow = 1 }),
			row("labels", "mission.labels", labels),
			if #i.goals > 0 then text("goals", table.concat(i.goals, " "), "mission.statusChip-active") else nil,
			text("age", M.ago(data.now, M.isoMs(i.updatedAt)) or "", "mission.goalProgress"),
		}, { actions = { click = "toggle=" .. i.ref }, mark = if i.ref == view.selectedRef then "pick" else nil, title = i.url })
		table.insert(rows, col("i" .. i.ref, "mission.item", { line, if openItems[i.ref] then detail("detail", i.body, {
			{ "Issue", i.url, "url=" .. i.url },
			{ "Labels", table.concat(i.labels, ", ") },
			{ "Updated", M.ago(data.now, M.isoMs(i.updatedAt)) },
			{ "Goals", table.concat(i.goals, ", ") },
		}, {
			{ "Make a goal", "issuegoal=" .. i.ref, true },
			{ "Link to a goal", "issuelink=" .. i.ref },
			{ "Open on GitHub", "url=" .. i.url },
			{ "Close as not planned", "issueclose=" .. i.ref },
		}) else nil }))
	end
	local out = {}
	for n, e in (data.errors or {}) do
		if n <= 2 then table.insert(out, text("err" .. tostring(n), e, "mission.notice")) end
	end
	local marked = 0
	for _ in view.marked do marked += 1 end
	table.insert(out, col("issues", "mission.section", {
		sectionHead("head", "Open issues", plural(#rows, "issue", "issues") .. " · fetched " .. (M.ago(data.now, data.fetched) or "")
			.. (if marked > 0 then " · " .. tostring(marked) .. " marked" else "")),
		if #rows > 0 then col("list", "mission.strips", rows)
			else text("none", "No open issues" .. (if view.repoFilter then " in " .. view.repoFilter else "") .. ".", "mission.empty"),
	}))
	return out
end

-- A goal's details: what done looks like, its issues, and buttons to reach it.
goalDetail = function(g, coordinator)
	local facts = { { "Coordinator", coordinator and (coordinator.ref .. (if coordinator.lastNote then " · " .. oneLine(coordinator.lastNote) else "")) } }
	for n, i in (g.issues or {}) do table.insert(facts, { if n == 1 then "Issues" else "", i.repo .. "#" .. tostring(i.number) .. " " .. i.title, "url=" .. i.url }) end
	return detail("detail", g.body, facts, {
		if g.status == "proposed" then { "Start goal", "start=" .. g.ref, true } else false,
		if coordinator and coordinator.status == "doing" then { "Go to coordinator", "go=" .. coordinator.ref, g.status ~= "proposed" } else false,
		if g.tern_session and (g.status == "active" or g.status == "finished") then { "Open session", "session=" .. g.ref } else false,
		if g.status == "finished" then { "Close goal", "close=" .. g.ref } else false,
	})
end

local GOAL_STATUS = { proposed = "Proposed", active = "Running", finished = "Finished", done = "Done", dropped = "Dropped" }

-- The Backlog tab: every goal (newest first, click to show its tasks) and every task outside goals.
-- A goal in the Backlog: its line (click opens its details and tasks), then those when open.
local function backlogGoal(view, entry, now)
	local g = entry.goal
	local open = view.expanded[g.ref] == true
	local progress = if g.progress and g.progress.total > 0 then tostring(g.progress.done) .. "/" .. tostring(g.progress.total) else ""
	local strips = {}
	if open then
		for _, t in entry.tasks do table.insert(strips, strip(t, t.ref == view.selectedRef, view.agentOf, {})) end
		if #strips == 0 then table.insert(strips, text("none", "No tasks.", "mission.empty")) end
	end
	return col("g" .. g.ref, "mission.backlogGoal", {
		row("line", "mission.backlogLine-" .. g.status, {
			text("chev", if open then "▾" else "▸", "mission.chev"),
			text("ref", g.ref, "mission.ref"),
			text("title", g.title, "mission.stripTitle", { grow = 1 }),
			text("progress", progress, "mission.goalProgress"),
			text("age", M.ago(now, g.closed or g.created) or "", "mission.goalProgress"),
			issueLinks(g.issues),
			text("status", GOAL_STATUS[g.status] or g.status, "mission.statusChip-" .. g.status),
			if g.status == "proposed" then ui.button("Start goal", { key = "start", variant = "primary",
				title = "Opens it in a session of its own; its coordinator plans the tasks", actions = { click = "start=" .. g.ref } }) else nil,
		}, { actions = { click = "expand=" .. g.ref }, mark = if g.ref == view.selectedRef then "pick" else nil }),
		if open then goalDetail(g, entry.coordinator) else nil,
		if open then col("tasks", "mission.backlogTasks", strips) else nil,
	})
end

-- Finished goals and tasks of one period, goals first, as a section; nil when empty.
local function doneSection(view, key, title, goals, tasks, note)
	local items = {}
	for _, entry in goals do table.insert(items, backlogGoal(view, entry, view.backlog.now)) end
	for _, t in tasks do table.insert(items, strip(t, t.ref == view.selectedRef, view.agentOf, {})) end
	if #items == 0 then return nil end
	return col(key, "mission.section", {
		sectionHead("head", title, plural(#goals, "goal", "goals") .. " · " .. plural(#tasks, "task", "tasks") .. (if note then " · " .. note else "")),
		col("list", "mission.strips", items),
	})
end

-- The Backlog tab: open goals (newest first, click to show its tasks), open
-- tasks outside goals, what finished today, and (d) what finished before.
-- Finished goals and tasks are deleted after 30 days.
local function backlogNodes(view)
	local b = view.backlog
	local out = {}
	if not b then return { text("loading", "Loading…", "mission.empty") } end
	local goals = {}
	for _, entry in b.goals do table.insert(goals, backlogGoal(view, entry, b.now)) end
	table.insert(out, col("goals", "mission.section", {
		sectionHead("head", "Goals", plural(#b.goals, "goal", "goals") .. " · Enter shows tasks · s starts a proposed one"),
		if #goals > 0 then col("list", "mission.strips", goals)
			else text("none", if view.repoFilter then "No open goals touch " .. view.repoFilter .. "." else "No open goals. Press g to propose one.", "mission.empty"),
	}))
	local loose = {}
	for _, t in b.loose do table.insert(loose, strip(t, t.ref == view.selectedRef, view.agentOf, {})) end
	table.insert(out, col("loose", "mission.section", {
		sectionHead("head", "Tasks outside goals", plural(#b.loose, "task", "tasks")),
		if #loose > 0 then col("list", "mission.strips", loose) else text("none", "None.", "mission.empty"),
	}))
	local today = doneSection(view, "today", "Done today", b.todayGoals, b.todayTasks)
	if today then table.insert(out, today) end
	local earlier = #b.earlierGoals + #b.earlierTasks
	if view.showDone then
		local section = doneSection(view, "earlier", "Done before today", b.earlierGoals, b.earlierTasks, "d hides · deleted after 30 days")
		if section then table.insert(out, section) end
	elseif earlier > 0 then
		table.insert(out, row("earlier", "mission.showDone", {
			text("text", plural(earlier, "goal or task", "goals and tasks") .. " finished before today · press d (or click) to show",
				"mission.sectionNote"),
		}, { actions = { click = "showdone" } }))
	end
	return out
end

-- The Repos tab: every repository Flightdeck knows (found by scanning, or
-- learned from agents), and whether agents may use it.
-- A repository's details: where it is, its remote, and each worktree with its
-- branch, changes, ahead/behind and last commit; buttons to open them and to
-- change what agents and the Issues tab see. `info`: /api/repos/<name>/info.
local function repoDetail(it, info)
	local children = {}
	if not info then
		table.insert(children, text("loading", "Reading its worktrees…", "mission.empty"))
	elseif info.error then
		table.insert(children, text("error", info.error, "mission.notice"))
	else
		local facts = {}
		for n, f in {
			{ "Folder", (string.gsub(it.path, "^/Users/[^/]+", "~")) },
			{ "Remote", info.url, info.url and ("url=" .. info.url) },
			{ "Default branch", info.defaultBranch },
		} do
			if f[2] then
				table.insert(facts, row("f" .. tostring(n), "mission.fact", {
					text("k", f[1], "mission.factKey"),
					text("v", f[2], if f[3] then "mission.factLink" else "mission.factValue", if f[3] then { actions = { click = f[3] } } else nil),
				}))
			end
		end
		table.insert(children, col("facts", "mission.facts", facts))
		local trees = {}
		for n, w in info.worktrees do
			local where = {}
			if w.main then table.insert(where, "primary checkout") end
			if not w.main and (w.ahead > 0 or w.behind > 0) then
				table.insert(where, tostring(w.ahead) .. " ahead, " .. tostring(w.behind) .. " behind " .. (info.defaultBranch or "main"))
			end
			if w.upstream and (w.upstream.ahead > 0 or w.upstream.behind > 0) then
				table.insert(where, tostring(w.upstream.ahead) .. "↑ " .. tostring(w.upstream.behind) .. "↓ remote")
			end
			if w.dirty then table.insert(where, "uncommitted +" .. tostring(w.added) .. " −" .. tostring(w.deleted)) end
			if w.conflicts then table.insert(where, "conflicts with " .. (info.defaultBranch or "main")) end
			local last = w.head and (w.head.sha .. " " .. w.head.subject .. (if M.ago(info.now, M.isoMs(w.head.at)) then " · " .. M.ago(info.now, M.isoMs(w.head.at)) else ""))
			table.insert(trees, row("w" .. tostring(n), "mission.worktree", {
				ui.el("div", { key = "dot", role = if w.conflicts then "mission.dot-failed" elseif w.dirty then "mission.dot-lost" else "mission.dot-idle" }),
				col("main", "mission.stripMain", {
					text("branch", w.branch or "(detached)", "mission.worktreeBranch"),
					text("state", table.concat(where, " · "), "mission.stripNote"),
					if last then text("last", last, "mission.stripNote") else nil,
				}, { grow = 1 }),
				ui.button("Open", { key = "open", size = "sm", title = (string.gsub(w.path, "^/Users/[^/]+", "~")), actions = { click = "openpath=" .. w.path } }),
			}))
		end
		table.insert(children, col("trees", "mission.worktrees", trees))
	end
	local buttons = {
		ui.button("Open space", { key = "space", variant = "primary", actions = { click = "openpath=" .. it.path } }),
		ui.button(if it.ignored then "Use for agents" else "Hide from agents", { key = "agents", actions = { click = "repo=" .. it.name } }),
		ui.button(if it.issuesIgnored then "Show issues" else "Hide issues", { key = "issues", actions = { click = "repoissues=" .. it.name } }),
		ui.button("Refresh", { key = "refresh", variant = "quiet", actions = { click = "repoinfo=" .. it.name } }),
	}
	if info and info.url then
		table.insert(buttons, 4, ui.button("Open on GitHub", { key = "gh", actions = { click = "url=" .. info.url } }))
	end
	table.insert(children, row("buttons", "mission.detailButtons", buttons))
	return col("detail", "mission.detail", children)
end

-- The Repos tab: every repository Flightdeck knows (found by scanning, or
-- learned from agents), and whether agents and the Issues tab use it. Click one
-- for its worktrees and actions.
local function repoNodes(view)
	if not view.repos then return { text("loading", "Loading…", "mission.empty") } end
	local rows, ignored, issuesHidden = {}, 0, 0
	for _, r in view.repos do
		local it = r.item
		if it.ignored then ignored += 1 elseif it.issuesIgnored then issuesHidden += 1 end
		local open = openItems[it.name] == true
		local line = row("line", if it.ignored then "mission.repoIgnored" else "mission.repo", {
			text("chev", if open then "▾" else "▸", "mission.chev"),
			text("name", it.name, "mission.repoName"),
			text("path", (string.gsub(it.path, "^/Users/[^/]+", "~")), "mission.repoPath", { grow = 1 }),
			text("source", if it.source == "learned" then "from an agent" else "found", "mission.goalProgress"),
			text("issues", if it.ignored or it.issuesIgnored then "Issues hidden" else "Issues shown",
				if it.ignored or it.issuesIgnored then "mission.statusChip-dropped" else "mission.statusChip-proposed"),
			text("state", if it.ignored then "Ignored" else "Used", if it.ignored then "mission.statusChip-dropped" else "mission.statusChip-finished"),
		}, { actions = { click = "toggle=" .. it.name }, mark = if it.name == view.selectedRef then "pick" else nil,
			title = "Click for its worktrees, branches and actions" })
		table.insert(rows, col("r" .. it.name, "mission.item", { line, if open then repoDetail(it, (view.repoInfo or {})[it.name]) else nil }))
	end
	return { col("repos", "mission.section", {
		sectionHead("head", "Repositories", plural(#view.repos, "known", "known") .. " · " .. tostring(ignored) .. " ignored · "
			.. tostring(issuesHidden) .. " with issues hidden · rescanned every 30 min"),
		if #rows > 0 then col("list", "mission.strips", rows) else text("none", "None found yet. Press s to scan.", "mission.empty"),
	}) }
end

-- Gives a builder's node a key (ui builders take none).
local function keyed(node, key)
	node.p = node.p or {}
	node.p.key = key
	return node
end

local function keyedStats(items)
	return keyed(ui.stats(items), "tiles")
end

-- "$12.34", or "$0.04" for small amounts. Pure.
function M.money(usd)
	return string.format("$%.2f", usd or 0)
end

-- "1.2M", "34k", "512". Pure.
function M.count(n)
	if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
	return tostring(math.floor(n))
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
-- "2026-11-16" → "16 Nov". Pure.
function M.shortDay(day)
	local _, m, d = string.match(day, "^(%d+)-(%d+)-(%d+)$")
	return if m then tostring(tonumber(d)) .. " " .. MONTHS[tonumber(m)] else day
end

-- A bar chart whose bars have tooltips. `bars`: { label, value, tip }. Heights
-- come in 20 steps (roles mission.bar-0 … mission.bar-20): view nodes take no
-- inline styles. The first and last labels sit under it.
local BAR_STEPS = 20
function M.barStep(value, max)
	if value <= 0 or max <= 0 then return 0 end
	return math.max(1, math.floor(value / max * BAR_STEPS + 0.5))
end

local function chart(bars)
	local max = 0
	for _, b in bars do max = math.max(max, b[2]) end
	local cols = {}
	for n, b in bars do
		table.insert(cols, ui.node("col", { key = "b" .. tostring(n), role = "mission.barCol", title = b[3] or (b[1] .. ": " .. tostring(b[2])) }, {
			ui.el("div", { key = "bar", role = "mission.bar-" .. tostring(M.barStep(b[2], max)) }),
		}))
	end
	local range = if #bars > 0 then bars[1][1] .. "  …  " .. bars[#bars][1] else ""
	return col("chart", "mission.chart", { row("bars", "mission.bars", cols), text("range", range, "mission.chartRange") })
end

-- The Stats tab: spend from omp's session files, agents over the day, how goals and tasks ended.
local function statsNodes(view)
	local a = view.stats
	if not a then return { text("loading", "Adding up omp's sessions…", "mission.empty") } end
	local t = a.totals
	local out = {}
	local now = a.agentsNow
	table.insert(out, keyedStats({
		{ label = "Spent today", value = M.money(a.spend.today) },
		{ label = "Last 7 days", value = M.money(a.spend.week) },
		{ label = "Last 30 days", value = M.money(a.spend.month), sub = M.count(a.spend.monthTokens) .. " tokens" },
		{ label = "Agents working", value = if now then tostring(now.working) else "–", sub = if now then "of " .. tostring(now.total) .. " running" else "no sample yet",
			tone = if now and now.working > 0 then "success" else nil },
		{ label = "Tasks done", value = tostring(t.tasksDone), sub = tostring(t.tasksFailed) .. " failed · " .. tostring(t.tasksOpen) .. " open",
			tone = if t.tasksFailed > 0 then nil else nil },
		{ label = "Goals done", value = tostring(t.goalsDone), sub = tostring(t.goalsActive) .. " running · " .. tostring(t.goalsDropped) .. " dropped" },
	}))

	local spendBars = {}
	for _, d in a.spendByDay do
		local lines = { M.shortDay(d.day) .. ": " .. M.money(d.cost) .. " · " .. M.count(d.tokens or 0) .. " tokens" }
		for _, p in (d.projects or {}) do table.insert(lines, p.project .. "  " .. M.money(p.cost)) end
		table.insert(spendBars, { M.shortDay(d.day), d.cost, table.concat(lines, "\n") })
	end
	table.insert(out, col("spend", "mission.section", { sectionHead("head", "Spend per day", "USD, last 14 days"), chart(spendBars) }))

	local agentBars = {}
	for _, h in a.agentsByHour do
		table.insert(agentBars, { h.hour, h.working, string.format("%s: %d working, %d waiting for you, %d running", h.hour, h.working, h.waiting or 0, h.total) })
	end
	table.insert(out, col("agents", "mission.section", { sectionHead("head", "Agents working", "busiest minute of each hour, last 24 hours"),
		chart(agentBars) }))

	local taskBars, failed = {}, 0
	for _, d in a.tasksByDay do
		local tip = M.shortDay(d.day) .. ": " .. tostring(d.done) .. " done" .. (if d.failed > 0 then ", " .. tostring(d.failed) .. " failed" else "")
		if d.titles and #d.titles > 0 then tip ..= "\n" .. table.concat(d.titles, "\n") end
		table.insert(taskBars, { M.shortDay(d.day), d.done, tip })
		failed += d.failed
	end
	table.insert(out, col("tasks", "mission.section", { sectionHead("head", "Tasks done per day", tostring(failed) .. " failed in the same 14 days"),
		chart(taskBars) }))

	local total = math.max(a.spend.month, 0.0001)
	local projectRows = {}
	for n, p in a.byProject do
		if n <= 10 then table.insert(projectRows, { id = p.project, cells = { p.project, ui.meter_cell(p.cost / total), M.money(p.cost) } }) end
	end
	table.insert(out, col("projects", "mission.section", { sectionHead("head", "Spend by project", "last 30 days"),
		keyed(ui.table({ { id = "p", head = "Project", grow = 1, mono = true }, { id = "share", head = "Share", grow = 1 }, { id = "cost", head = "Cost", align = "end" } },
			projectRows, { empty = "No spend recorded yet." }), "projectTable") }))

	local modelRows = {}
	for _, m in a.byModel do table.insert(modelRows, { id = m.model, cells = { m.model, M.count(m.tokens), M.money(m.cost) } }) end
	table.insert(out, col("models", "mission.section", { sectionHead("head", "Spend by model", "last 30 days"),
		keyed(ui.table({ { id = "m", head = "Model", grow = 1, mono = true }, { id = "tok", head = "Tokens", align = "end" }, { id = "cost", head = "Cost", align = "end" } },
			modelRows, { empty = "No spend recorded yet." }), "modelTable") }))

	local goalRows = {}
	for _, g in a.byGoal do
		table.insert(goalRows, { id = g.ref, cells = { g.ref, g.title, GOAL_STATUS[g.status] or g.status, tostring(g.tasks), M.money(g.cost) } })
	end
	table.insert(out, col("goals", "mission.section", { sectionHead("head", "Goals", "coordinator and workers, with their subagents"),
		keyed(ui.table({ { id = "ref", head = "Goal", mono = true }, { id = "title", head = "Title", grow = 1 }, { id = "status", head = "Status" },
			{ id = "tasks", head = "Tasks", align = "end" }, { id = "cost", head = "Cost", align = "end" } }, goalRows, { empty = "No goals yet." }), "goalTable") }))
	return out
end

-- The whole block. `view`: { tab, open (refs showing details), repoInfo, showDone, sections, backlog, expanded, repos, repoChoices, repoFilter, selectedRef, thread,
-- reply, replyTo, replyHint, error, agentOf }. Sections and backlog arrive already filtered.
-- Returns the block's main and dock nodes.
function M.view(view)
	openItems = view.open or {}
	openThreadRef = view.thread and view.thread.task
	local s = view.sections
	local agentOf = view.agentOf or function() return nil end
	local waitingTasks = {}
	for _, q in s.needs do waitingTasks[q.task] = true end
	local main = {}

	table.insert(main, col("header", "mission.header", {
		text("title", "Mission control", "mission.title"),
		text("summary", summary(s, agentOf), "mission.summary"),
	}))
	table.insert(main, tabStrip(view.tab or "now", #s.needs))
	-- The toolbar: the repository filter on the left, the tab's actions on the right.
	local tools = {}
	if view.tab ~= "repos" and view.tab ~= "stats" then
		local bar = filterBar(view.repoChoices or {}, view.repoFilter, view.filterOpen, view.filterHover)
		if bar then table.insert(tools, bar) end
	end
	table.insert(tools, ui.node("row", { key = "spacer", grow = 1 }, {}))
	local function button(key, label, act, primary, icon)
		table.insert(tools, ui.button(label, { key = key, variant = if primary then "primary" else "default", icon = icon, actions = { click = act } }))
	end
	if view.tab == "now" or view.tab == "backlog" then
		if view.tab == "backlog" then button("done", if view.showDone then "Hide older done" else "Show older done", "showdone") end
		button("task", "New task", "newtask", false, "plus")
		button("goal", "New goal", "newgoal", true, "plus")
	elseif view.tab == "issues" then
		button("refresh", "Refresh issues", "refreshissues", false, "refresh")
	elseif view.tab == "stats" then
		button("refresh", "Refresh", "refreshstats", false, "refresh")
	elseif view.tab == "repos" then
		button("scan", "Scan for repositories", "scanrepos", false, "refresh")
	end
	table.insert(main, row("toolbar", "mission.toolbar", tools))
	if view.error then table.insert(main, text("error", view.error, "mission.notice")) end
	if view.tab == "stats" then
		for _, node in statsNodes(view) do table.insert(main, node) end
		return ui.node("scroll", { key = "main", role = "mission.main" }, main), dockNode(view, "[ ] tabs   r refresh")
	end
	if view.tab == "issues" then
		for _, node in issueNodes(view) do table.insert(main, node) end
		return ui.node("scroll", { key = "main", role = "mission.main" }, main),
			dockNode(view, "[ ] tabs   f repo   ↑↓ move   e details   Enter goal from issue   space mark   l link to goal   o open   x close   r refresh")
	end
	if view.tab == "repos" then
		for _, node in repoNodes(view) do table.insert(main, node) end
		return ui.node("scroll", { key = "main", role = "mission.main" }, main),
			dockNode(view, "[ ] tabs   ↑↓ move   Enter / e details   a hide / use for agents   i hide / show issues   s scan now")
	end
	if view.tab == "backlog" then
		view.agentOf = agentOf
		for _, node in backlogNodes(view) do table.insert(main, node) end
		if view.thread then table.insert(main, threadSection(view.thread, s.now)) end
		return ui.node("scroll", { key = "main", role = "mission.main" }, main),
			dockNode(view, "[ ] tabs   f repo   ↑↓ move   Enter / e details   d done   s start goal   o thread   n new task   g new goal")
	end

	-- Your turn
	if #s.needs > 0 then
		local cards = {}
		for _, q in s.needs do
			local picked = "q:" .. q.task == view.selectedRef
			local reply
			if picked and view.replyInCard then
				reply = Input.props(view.reply)
				reply.key, reply.role = "reply", "mission.cardReply"
				reply.placeholder = if q.options and #q.options > 0 then "Press a number, or type your own answer and press Enter"
					else "Type your answer and press Enter"
			end
			table.insert(cards, questionNode(q, picked, s.now, reply))
		end
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
			local finished = g.status == "finished"
			local progress = if finished then "Finished · review, then close"
				elseif g.progress then tostring(g.progress.done) .. " of " .. tostring(g.progress.total) .. " done" else ""
			if openItems[g.ref] then table.insert(strips, 1, goalDetail(g, group.coordinator)) end
			table.insert(goalPanels, panel("g" .. g.ref, col("head", "mission.goalHead", {
				row("line", "mission.goalLine", {
					text("ref", g.ref, "mission.ref"),
					text("title", g.title, "mission.goalTitle", { grow = 1 }),
					if group.coordinator and not finished then (function()
						local key, label = M.taskState(group.coordinator, agentOf(group.coordinator.session), waitingTasks[group.coordinator.ref])
						return row("coord", "mission.coordinator", {
							ui.el("div", { key = "dot", role = "mission.dot-" .. key }),
							text("label", "Coordinator " .. string.lower(label), "mission.stateLabel"),
						}, { title = group.coordinator.ref .. " · " .. (oneLine(group.coordinator.lastNote) or group.coordinator.title) })
					end)() else nil,
					text("progress", progress, "mission.goalProgress"),
					ui.el("button", { key = "open", role = "mission.quiet", text = "Open session",
						actions = { click = "session=" .. g.ref } }),
					if finished then ui.button("Close goal", { key = "close", variant = "primary",
						title = "Mark it done and close its session; the worktrees stay", actions = { click = "close=" .. g.ref } }) else nil,
				}),
				rail(group.tasks, agentOf, waitingTasks),
				issueLinks(g.issues),
			}, { actions = { click = "toggle=" .. g.ref }, title = "Show the goal's details" }), strips))
		else
			loose = strips
		end
	end
	if #goalPanels > 0 then
		table.insert(main, col("goals", "mission.section", { sectionHead("head", "Goals", plural(#goalPanels, "goal", "goals")), col("list", "mission.panels", goalPanels) }))
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

	if view.thread then table.insert(main, threadSection(view.thread, s.now)) end

	return ui.node("scroll", { key = "main", role = "mission.main" }, main),
		dockNode(view, "[ ] tabs   f repo   ↑↓ move   e details   1–9 answer   Enter go to agent   o thread   r review   n new task   g new goal")
end

do
	assert(M.isoMs("1970-01-02T00:00:01Z") == 86401000 and M.isoMs("2026-11-16T10:00:00Z") - M.isoMs("2026-11-15T10:00:00Z") == 86400000,
		"ui.render.isoMs self-check")
	assert(M.barStep(0, 10) == 0 and M.barStep(0.1, 10) == 1 and M.barStep(10, 10) == 20 and M.barStep(5, 0) == 0, "ui.render.barStep self-check")
	assert(M.money(1.234) == "$1.23" and M.count(1234567) == "1.2M" and M.count(8.07e9) == "8.1B" and M.count(34000) == "34k" and M.shortDay("2026-11-06") == "6 Nov",
		"ui.render money/count/shortDay self-check")
	assert(M.oneLine("**Done**: `a`\n b") == "Done: a b" and M.oneLine("accepts apple_pay") == "accepts apple_pay", "ui.render.oneLine self-check")
	assert(M.ago(120000, 0) == "2 min ago" and M.ago(1000, 0) == "just now" and M.ago(nil, 0) == nil, "ui.render.ago self-check")
	assert(select(2, M.taskState({ status = "todo", goal = 1, needs = { { ref = "G2.1", status = "doing" }, { ref = "G2.2", status = "done" } } })) == "Waiting on G2.1"
		and M.refList({ "a", "b", "c", "d" }) == "a, b +2", "ui.render dependencies self-check")
	assert(M.taskState({ status = "doing" }, nil) == "lost" and M.taskState({ status = "doing" }, "working") == "working"
		and M.taskState({ status = "todo" }, nil, true) == "waiting", "ui.render.taskState self-check")
	local sections = { now = 0, needs = { { task = "T-1", title = "t", question = "Q?", options = { "a", "b" }, recommended = 1 } },
		proposed = { { ref = "G-2", title = "p" } },
		working = { { goal = { ref = "G-1", title = "g", progress = { done = 0, total = 1 } }, tasks = { { ref = "T-2", title = "x", status = "doing", session = "s" } } } },
		todo = {} }
	local main, dock = M.view({ sections = sections, selectedRef = "T-1", reply = Input.new(""), replyTo = "T-1",
		repoChoices = { "a" }, repoFilter = "a", agentOf = function() return "working" end })
	assert(main ~= nil and dock ~= nil, "ui.render.view self-check")
	local backlog = { now = 0, goals = { { goal = { ref = "G-1", title = "g", status = "active", created = 0 }, tasks = { { ref = "T-2", title = "x", status = "done" } } } }, loose = {},
		todayGoals = {}, todayTasks = { { ref = "T-3", title = "y", status = "done" } }, earlierGoals = {}, earlierTasks = { { ref = "T-4", title = "z", status = "done" } } }
	local bm = M.view({ tab = "backlog", sections = sections, backlog = backlog, expanded = { ["G-1"] = true }, showDone = true, reply = Input.new("") })
	assert(bm ~= nil, "ui.render.view backlog self-check")
end

return M
