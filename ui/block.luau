-- The Mission control block (host half): wires ui/model.luau (data),
-- ui/render.luau (view) and ui/dialog.luau (popup forms) into a Tern plugin
-- block with buttons, keys, an answer field and a 2-second refresh. Actions the host can't take (open a goal's
-- session, focus a pane, open a review tab) go to the window as requests.
local Input = require("../input")
local model = require("./model")
local render = require("./render")
local dialog = require("./dialog")

local POLL_MS = 2000

local ISSUES_POLL_MS = 30000
local STATS_POLL_MS = 60000
local issueKey
local publishLinkBase
local askClose

local EMPTY = { needs = {}, proposed = {}, working = {}, todo = {} }

-- Sections and backlog narrowed to the repository filter (state.repoFilter, nil: all).
local function shown(state)
	return model.filterSections(state.sections, state.repoFilter), model.filterBacklog(state.backlog, state.repoFilter)
end

-- A row's selection key: its ref, but "q:G1.1" for a question, since the
-- question and its task share a ref and both show on Now.
local function rowKey(r)
	return if r.kind == "question" then "q:" .. r.item.task else (r.item.task or r.item.ref)
end

-- The selectable rows of the shown tab and the index of the selected one (by key, so a refresh keeps it).
local function rows(state)
	local sections, backlog = shown(state)
	local list = if state.tab == "backlog" then (if backlog then model.backlogRows(backlog, state.expanded, state.showDone) else {})
		elseif state.tab == "issues" then model.issueRows(state.issues, state.repoFilter)
		elseif state.tab == "repos" then (state.repos or {})
		else model.selectable(sections)
	local index = 1
	for i, r in list do
		if rowKey(r) == state.selectedRef then index = i end
	end
	return list, index
end

local function selectedRow(state)
	local list, index = rows(state)
	return list[index]
end

-- Who the reply field writes to: the open thread, else the selected question.
local function replyTarget(state)
	if state.thread then return state.thread.task, nil end
	if state.tab ~= "now" then return nil, nil end
	local row = selectedRow(state)
	-- The selected question's answer field sits in its card (third value).
	if row and row.kind == "question" then return row.item.task, nil, true end
	return nil, nil
end

local function refresh(state, cx)
	model.api("GET", "/api/state", nil, function(s, err)
		state.error = err
		if s then state.sections = model.sections(s) end
		-- The sidebar's Close goal asks here.
		local closing = tern.kv.get("mission:closeGoal")
		if type(closing) == "string" then tern.kv.set("mission:closeGoal", nil); askClose(state, cx, closing) end
		local pending = tern.kv.get("mission:select")
		if type(pending) == "string" then state.selectedRef = pending; tern.kv.set("mission:select", nil) end
		if state.tab == "repos" then
			model.api("GET", "/api/repos", nil, function(data)
				if data then state.repos = model.repoRows(data) end
				pcall(function() cx:render() end)
			end)
		end
		-- Issues: the server caches gh's answer; fetch it at most every ISSUES_POLL_MS.
		if state.tab == "issues" and (not state.issuesAt or tern.now() - state.issuesAt > ISSUES_POLL_MS) then
			state.issuesAt = tern.now()
			model.api("GET", "/api/issues" .. (if state.issuesRefresh then "?refresh=1" else ""), nil, function(data, issuesErr)
				if data then state.issues = data end
				if issuesErr then state.error = issuesErr end
				pcall(function() cx:render() end)
			end)
			state.issuesRefresh = false
		end
		if state.tab == "stats" and (not state.statsAt or tern.now() - state.statsAt > STATS_POLL_MS) then
			state.statsAt = tern.now()
			model.api("GET", "/api/analytics", nil, function(data, statsErr)
				if data then state.stats = data end
				if statsErr then state.error = statsErr end
				pcall(function() cx:render() end)
			end)
		end
		-- Every tab: the backlog also gives the repository filter its choices.
		do
			model.api("GET", "/api/backlog", nil, function(data)
				if data then state.backlog = model.backlog(data) end
				pcall(function() cx:render() end)
			end)
		end
		if state.thread then
			model.api("GET", "/api/thread/" .. state.thread.task, nil, function(events)
				if events and state.thread then state.thread.events = events end
				pcall(function() cx:render() end)
			end)
		end
		local ok = pcall(function() cx:render() end)
		state.alive = ok
	end)
end

local function poll(state, cx)
	tern.timer(POLL_MS, function()
		if state.alive == false then return end
		refresh(state, cx)
		poll(state, cx)
	end)
end

local function openThread(state, cx, task)
	state.thread = { task = task, events = {} }
	refresh(state, cx)
end

local function send(state, cx)
	local body = state.reply.text
	if not string.find(body, "%S") then return end
	local target = replyTarget(state)
	if target then
		model.api("POST", "/api/answer", { task = target, body = body }, function(_, err) state.error = err; refresh(state, cx) end)
	end
	state.reply = Input.new("")
end

-- Opens a popup form (ui/dialog.luau): "goal", "task" or "link".
local function openDialog(state, kind, opts)
	if kind == "task" and not (opts and opts.repo) then
		local row = selectedRow(state)
		opts = { repo = state.repoFilter or (row and row.item.repo) or nil }
	end
	state.dialog = dialog.new(kind, opts)
end

-- Sends the open dialog; it closes once the server accepts it, else shows the error.
local function submitDialog(state, cx)
	local d = state.dialog
	if not d then return end
	if dialog.missing(d) then d.focus, d.error = dialog.missing(d), "Fill this in first."; return end
	local v = dialog.values(d)
	local function done(message)
		return function(result, err)
			if err then d.error = err
			else
				if state.dialog == d then state.dialog = nil end
				state.error = message(result)
			end
			state.issuesAt = nil
			refresh(state, cx)
		end
	end
	if d.kind == "goal" then
		model.api("POST", "/api/goals", { title = v.title, body = v.body, issues = d.issues }, done(function(g)
			state.marked = {}
			return g.ref .. " proposed. Start it from Backlog when you're ready; its coordinator plans the tasks."
		end))
	elseif d.kind == "task" then
		model.api("POST", "/api/tasks", { title = v.title, repo = v.repo }, done(function(t) return "Task added." end))
	elseif d.kind == "close" then
		model.api("POST", "/api/goals/" .. d.goal .. "/close", { status = "done", removeMerged = true }, done(function(r)
			model.request({ kind = "closed", goal = d.goal, session = d.session })
			return d.goal .. " closed" .. (if r and r.removing and r.removing > 0 then "; removing " .. tostring(r.removing) .. " merged worktree(s)." else ".")
		end))
	elseif d.kind == "link" then
		local goal = string.upper((string.gsub(v.goal, "%s", "")))
		model.api("POST", "/api/goals/" .. goal .. "/issues", { issue = d.issue }, done(function() return d.issue .. " linked to " .. goal .. "." end))
	end
end

local function answerOption(state, cx, task, option)
	local q
	for _, item in state.sections.needs do if item.task == task then q = item end end
	local text = q and q.options and q.options[option]
	if not text then return false end
	model.api("POST", "/api/answer", { task = task, body = text }, function(_, err) state.error = err; refresh(state, cx) end)
	return true
end

-- Hides a repository from agents, or uses it again.
local function toggleRepo(state, cx, repo)
	model.api("POST", "/api/repos/" .. repo.name .. "/ignore", { ignored = not repo.ignored }, function(_, err)
		state.error = err
		refresh(state, cx)
	end)
	repo.ignored = not repo.ignored
end

local function choices(state)
	return model.repoChoices(state.backlog, state.issues and state.issues.issues)
end

-- Opens the repository menu with the current choice under the keyboard.
local function openFilter(state)
	state.filterOpen, state.filterHover = true, 1
	for i, name in choices(state) do
		if name == state.repoFilter then state.filterHover = i + 1 end
	end
end

-- Issues tab keys. Returns whether `name` was handled.
-- Enter: a proposed goal from the marked issues (asks a title) or the selected one.
-- space: mark. l: link to a goal. o: open on GitHub. x twice: close as not planned. r: refetch.
issueKey = function(state, cx, name, row)
	local issue = row and row.item
	local confirming = state.confirmClose
	state.confirmClose = nil
	if name == "r" then
		state.issuesAt, state.issuesRefresh, state.error = nil, true, "Fetching issues…"
		refresh(state, cx)
	elseif not issue then
		return false
	elseif name == "space" then
		state.marked[issue.ref] = not state.marked[issue.ref] or nil
	elseif name == "enter" then
		local refs = {}
		for ref in state.marked do table.insert(refs, ref) end
		if #refs > 0 then
			table.sort(refs)
			openDialog(state, "goal", { issues = refs })
		else
			model.api("POST", "/api/goals", { title = issue.title, body = issue.body .. "\n\n" .. issue.url, issues = { issue.ref } }, function(g, err)
				state.error = err or (g and (g.ref .. " proposed from " .. issue.ref .. ". Start it from Backlog."))
				state.issuesAt = nil
				refresh(state, cx)
			end)
		end
	elseif name == "l" then
		openDialog(state, "link", { issue = issue.ref })
	elseif name == "o" then
		model.request({ kind = "url", url = issue.url })
	elseif name == "x" then
		if confirming ~= issue.ref then
			state.confirmClose, state.error = issue.ref, "Press x again to close " .. issue.ref .. " on GitHub as not planned."
		else
			model.api("POST", "/api/issues/close", { issue = issue.ref, reason = "not planned" }, function(_, err)
				state.error = err or (issue.ref .. " closed as not planned.")
				state.issuesAt = nil
				refresh(state, cx)
			end)
		end
	else
		return false
	end
	return true
end

-- Hides a repository's issues from the Issues tab, or shows them again; agents still see the repository.
local function toggleRepoIssues(state, cx, repo)
	model.api("POST", "/api/repos/" .. repo.name .. "/ignore-issues", { ignored = not repo.issuesIgnored }, function(_, err)
		state.error, state.issuesAt = err, nil
		refresh(state, cx)
	end)
	repo.issuesIgnored = not repo.issuesIgnored
end

-- Close goal: fetch its worktrees and their PRs, then ask (ui/dialog.luau "close").
askClose = function(state, cx, ref)
	local session
	for _, group in state.sections.working do
		if group.goal and group.goal.ref == ref then session = group.goal.tern_session end
	end
	state.error = "Checking " .. ref .. "'s worktrees and PRs…"
	model.api("GET", "/api/goals/" .. ref .. "/worktrees", nil, function(r, err)
		state.error = err
		if r then state.dialog = dialog.new("close", { goal = ref, session = session, worktrees = r.worktrees }) end
		pcall(function() cx:render() end)
	end)
end

local function scanRepos(state, cx)
	state.error = "Scanning for repositories…"
	model.api("POST", "/api/repos/scan", {}, function(r, err)
		state.error = err or (r and string.format("Scan done: %d added, %d removed%s.", r.added, r.removed,
			if #r.duplicates > 0 then string.format(", %d skipped (name already taken)", #r.duplicates) else ""))
		refresh(state, cx)
	end)
end

local function switchTab(state, cx, tab)
	state.tab, state.thread = tab, nil
	refresh(state, cx)
end

-- The tab after (step 1) or before (step -1) the shown one.
local function stepTab(state, step)
	local index = 1
	for i, t in render.TABS do if t.id == state.tab then index = i end end
	return render.TABS[(index - 1 + step) % #render.TABS + 1].id
end

-- Enter on a row with an empty reply: start a proposal, go to a task's agent, show a goal's tasks.
local function activate(state, cx)
	local row = selectedRow(state)
	if not row then return end
	if row.kind == "repo" then
		toggleRepo(state, cx, row.item)
	elseif row.kind == "goal" then
		state.expanded[row.item.ref] = not state.expanded[row.item.ref] or nil
	elseif row.kind == "proposal" then
		model.request({ kind = "start", goal = row.item.ref })
		state.error = "Starting " .. row.item.ref .. " in a session of its own…"
	elseif row.kind == "task" or row.kind == "todo" then
		model.request({ kind = "go", task = row.item.ref })
	end
end

-- Where relative file links in what's shown resolve: the selected item's
-- task folder (its worktree, else its repository), for the window's link
-- route (kv `mission:linkBase`; see missionLinks in window.luau).
local publishedBase = nil
publishLinkBase = function(state, row)
	local ref = row and (row.item.task or row.item.ref)
	local base
	for _, group in state.sections.working do
		for _, t in group.tasks do if t.ref == ref then base = t.worktree or t.repoPath end end
		if group.coordinator and group.coordinator.ref == ref then base = group.coordinator.worktree or group.coordinator.repoPath end
	end
	if not base and row and row.item.worktree then base = row.item.worktree end
	if base ~= publishedBase then
		publishedBase = base
		tern.kv.set("mission:linkBase", base)
	end
end

local DEF = {
	init = function(cx, args, saved)
		local state = {
			sections = EMPTY, selectedRef = args[1], thread = nil,
			repoFilter = if type(saved) == "table" and type(saved.repoFilter) == "string" then saved.repoFilter else nil,
			tab = "now", backlog = nil, expanded = {}, marked = {}, open = {},
			reply = Input.new(""), dialog = nil, error = nil, alive = true,
		}
		refresh(state, cx)
		poll(state, cx)
		return state
	end,
	title = function(state)
		local n = #state.sections.needs
		return "Mission control" .. (if n > 0 then " (" .. tostring(n) .. ")" else "")
	end,
	view = function(state)
		local list, index = rows(state)
		local row = list[index]
		publishLinkBase(state, row)
		local to, hint, inCard = replyTarget(state)
		local agents = tern.kv.get("mission:agents")
		local sections, backlog = shown(state)
		local main, dock = render.view({
			tab = state.tab, stats = state.stats, backlog = backlog, expanded = state.expanded, repos = state.repos, open = state.open, showDone = state.showDone,
			repoChoices = choices(state), repoFilter = state.repoFilter,
			issues = state.issues, issueRows = model.issueRows(state.issues, state.repoFilter), marked = state.marked,
			filterOpen = state.filterOpen, filterHover = state.filterHover,
			sections = sections, selectedRef = row and rowKey(row),
			thread = state.thread, reply = state.reply, replyTo = to, replyHint = hint, replyInCard = inCard, error = state.error,
			agentOf = function(session) return if type(agents) == "table" and session then agents[session] else nil end,
		})
		return { main = main, dock = dock, layer = if state.dialog then dialog.node(state.dialog) else nil }
	end,
	key = function(state, key, cx)
		local list, index = rows(state)
		-- An open popup form takes every key.
		if state.dialog then
			local result = dialog.key(state.dialog, key)
			if result == "cancel" then state.dialog = nil
			elseif result == "submit" then submitDialog(state, cx) end
			return true
		end
		local typing = state.reply.text ~= ""
		-- The open repository menu takes the arrows, Enter and Esc.
		if state.filterOpen then
			local names = choices(state)
			if key.name == "up" or key.name == "down" then
				state.filterHover = math.clamp(state.filterHover + (if key.name == "up" then -1 else 1), 1, #names + 1)
			elseif key.name == "enter" then
				state.repoFilter, state.filterOpen = if state.filterHover == 1 then nil else names[state.filterHover - 1], false
			elseif key.name == "escape" or key.name == "esc" or key.name == "f" then
				state.filterOpen = false
			end
			return true
		end
		if key.name == "up" or key.name == "down" then
			local next = list[math.clamp(index + (if key.name == "up" then -1 else 1), 1, math.max(#list, 1))]
			if next then state.selectedRef = rowKey(next) end
		elseif not typing and state.tab == "issues" and issueKey(state, cx, key.name, list[index]) then
			-- handled
		elseif key.name == "escape" or key.name == "esc" then
			if state.reply.text ~= "" then state.reply = Input.new("")
			elseif state.thread then state.thread = nil
			elseif state.repoFilter then state.repoFilter = nil
			else return false end
		elseif not typing and (key.name == "[" or key.name == "]" or key.name == "bracketleft" or key.name == "bracketright") then
			switchTab(state, cx, stepTab(state, if key.name == "[" or key.name == "bracketleft" then -1 else 1))
		elseif key.name == "enter" then
			if typing then send(state, cx) else activate(state, cx) end
		elseif not typing and string.match(key.name, "^[1-9]$") then
			local row = list[index]
			if not (row and row.kind == "question" and answerOption(state, cx, row.item.task, tonumber(key.name))) then return false end
		elseif not typing and key.name == "o" then
			local row = list[index]
			if not row or row.kind == "proposal" or row.kind == "goal" then return false end
			openThread(state, cx, row.item.task or row.item.ref)
		elseif not typing and key.name == "r" and state.tab == "stats" then
			state.statsAt = nil
			refresh(state, cx)
		elseif not typing and key.name == "r" then
			local row = list[index]
			if not row or row.kind ~= "task" then return false end
			model.request({ kind = "review", task = row.item.ref })
		elseif not typing and key.name == "f" and state.tab ~= "repos" then
			openFilter(state)
		elseif not typing and key.name == "d" and state.tab == "backlog" then
			state.showDone = not state.showDone
		elseif not typing and key.name == "e" then
			-- Details of the selected item (a Backlog goal opens to its tasks too).
			local row = list[index]
			if not row then return false end
			local ref = row.item.ref or row.item.task
			if row.kind == "goal" then state.expanded[ref] = not state.expanded[ref] or nil
			else state.open[ref] = not state.open[ref] or nil end
		elseif not typing and key.name == "s" and state.tab == "backlog" then
			local row = list[index]
			if not (row and row.kind == "goal" and row.item.status == "proposed") then return false end
			model.request({ kind = "start", goal = row.item.ref })
			state.error = "Starting " .. row.item.ref .. " in a session of its own…"
		elseif not typing and key.name == "n" then
			openDialog(state, "task")
		elseif not typing and key.name == "i" and state.tab == "repos" then
			local row = list[index]
			if not row then return false end
			toggleRepoIssues(state, cx, row.item)
		elseif not typing and key.name == "s" and state.tab == "repos" then
			scanRepos(state, cx)
		elseif not typing and key.name == "g" then
			openDialog(state, "goal")
		else
			if not replyTarget(state) then return false end
			local handled, err = Input.key(state.reply, key)
			if not handled then return false end
			state.error = err
		end
		return true
	end,
	event = function(state, ev, cx)
		-- Table rows: a click selects, a double click goes to the agent (or starts the goal).
		-- Toolbar buttons and the popup form.
		if ev.ev == "action" then
			if ev.act == "showdone" then state.showDone = not state.showDone; return end
			if ev.act == "newgoal" then openDialog(state, "goal"); return end
			if ev.act == "newtask" then openDialog(state, "task"); return end
			if ev.act == "scanrepos" then scanRepos(state, cx); return end
			if ev.act == "refreshissues" then issueKey(state, cx, "r", nil); return end
			if ev.act == "refreshstats" then state.statsAt = nil; refresh(state, cx); return end
			if ev.act == "dialog" and state.dialog then
				if ev.value == "cancel" then state.dialog = nil else submitDialog(state, cx) end
				return
			end
			if ev.act == "field" and state.dialog then
				state.dialog.focus = math.clamp(tonumber(ev.value) or 1, 1, #state.dialog.fields)
				return
			end
		end
		if ev.ev == "action" and ev.act == "filtermenu" then
			if state.filterOpen then state.filterOpen = false else openFilter(state) end
			return
		end
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			state.selectedRef = ev.item
			if ev.ev == "activate" then activate(state, cx) end
			return
		end
		if ev.ev == "action" and ev.act == "start" and type(ev.item) == "string" then
			model.request({ kind = "start", goal = ev.item }); state.error = "Starting " .. ev.item .. " in a session of its own…"
			return
		end
		if ev.ev == "action" and ev.act == "url" and type(ev.value) == "string" then
			model.request({ kind = "url", url = ev.value })
			return
		end
		if ev.ev ~= "action" or type(ev.act) ~= "string" then return end
		-- Tern splits "verb=value" actions at the first "="; put them back together.
		local act = if ev.value ~= nil then ev.act .. "=" .. tostring(ev.value) else ev.act
		local verb, a, b = string.match(act, "^(%a+)=([^=]+)=?(.*)$")
		if verb == "answer" then answerOption(state, cx, a, tonumber(b))
		elseif verb == "select" then state.selectedRef = a
		elseif verb == "tab" then switchTab(state, cx, a)
		elseif verb == "repo" then
			state.selectedRef = a
			for _, r in (state.repos or {}) do if r.item.name == a then toggleRepo(state, cx, r.item) end end
		elseif verb == "repoissues" then
			state.selectedRef = a
			for _, r in (state.repos or {}) do if r.item.name == a then toggleRepoIssues(state, cx, r.item) end end
		elseif verb == "toggle" then
			state.selectedRef = a
			state.open[a] = not state.open[a] or nil
		elseif verb == "go" then model.request({ kind = "go", task = a })
		elseif verb == "thread" then
			-- Toggles: the same task's Thread button closes it.
			if state.thread and state.thread.task == a then state.thread = nil else openThread(state, cx, a) end
		elseif verb == "review" then model.request({ kind = "review", task = a })
		elseif verb == "issuegoal" or verb == "issuelink" or verb == "issueclose" then
			-- The issue's detail buttons do what its keys do.
			for _, r in model.issueRows(state.issues, nil) do
				if r.item.ref == a then
					state.selectedRef = a
					if verb == "issueclose" and state.confirmClose ~= a then state.confirmClose = nil end
					issueKey(state, cx, if verb == "issuegoal" then "enter" elseif verb == "issuelink" then "l" else "x", r)
				end
			end
		elseif verb == "mark" then state.marked[a] = not state.marked[a] or nil
		elseif verb == "filter" then state.repoFilter, state.filterOpen = if a == "*" then nil else a, false
		elseif verb == "expand" then state.selectedRef = a; state.expanded[a] = not state.expanded[a] or nil
		elseif verb == "session" then model.request({ kind = "session", goal = a })
		elseif verb == "close" then askClose(state, cx, a)
		elseif verb == "start" then model.request({ kind = "start", goal = a }); state.error = "Starting " .. a .. " in a session of its own…"
		end
	end,
	save = function(state)
		return { repoFilter = state.repoFilter }
	end,
}
tern.block.define("mission", DEF)
