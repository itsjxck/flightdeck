--!nonstrict
local wt = require("./worktrunk")
local view = require("./view")
local visualize = require("./visualize")
local oplog = require("./oplog")
local mission = require("./mission")
local unlock = require("./unlock")
local unlockKey

local cache = {}
local inflight = {}
-- Helper liveness probes: job id -> true while `kill -0` runs; dead[id] once it failed.
local probing, dead = {}, {}
-- Creations' progress, read from their setup tab (see trackCreations): job id
-- -> { step, asking, needsYou, quiet, changedAt, … }. In memory only.
local creationProgress = {}
local rendered = {}
local collapsed = {}
local confirmation
local problem
local lastRefresh = -15000
-- Whether ↻ is spinning for an explicit refresh.
local spinning = false
local sequence = 0
-- Defined after forms(); openForm starts it.
local watchForms

local function records(key)
	local value = tern.kv.get(key)
	if value == nil then return {} end
	assert(type(value) == "table", "Overseer storage is invalid: " .. key)
	return value
end

-- Git repositories found under spaces' folders, by shared Git directory, as
-- wt.inspect describes them: {id, name, path (primary checkout), base}.
local repos = {}
-- A folder's repository id, or false when it isn't in one; nil until inspected.
local dirRepo = {}
local inspecting = {}

-- The repository with any base branch chosen in Change base branch.
local function repoById(id)
	local repo = id and repos[id]
	if not repo then return nil end
	local base = records("repo-base")[id]
	if base then
		repo = table.clone(repo)
		repo.base = base
	end
	return repo
end

-- What mission.luau needs from the window: the repositories Spaces knows.
local function repoNamed(name)
	for id, repo in repos do
		if repo.name == name then return repoById(id) end
	end
	return nil
end
-- The session Mission control lives in, hidden from Spaces.
local MISSION_SESSION = "Mission control"
local missionHooks = {
	repoPath = function(name) local repo = repoNamed(name); return repo and repo.path end,
	baseFor = function(name) local repo = repoNamed(name); return if repo and repo.base ~= "" then repo.base else nil end,
}

local function localHost(cx)
	return cx.hosts:current().kind == "local"
end

local function requireLocal(cx)
	if localHost(cx) then return true end
	cx:toast("error", "Local host required", "Switch to the local host.")
	return false
end

-- Keep variable labels short without cutting a UTF-8 character.
local function notificationLabel(label)
	if utf8.len(label) <= 32 then return label end
	return label:sub(1, utf8.offset(label, 32) - 1) .. "…"
end

local function report(cx, text, title)
	problem = tostring(text)
	tern.log.warn(problem)
	local description = if #problem <= 40 and not problem:find("[\r\n]")
		then problem else "See Tern’s log for details."
	cx:toast("error", title or "Action failed", description)
end

local function sessionsById(cx)
	local result = {}
	for _, session in cx.sessions:list() do result[tostring(session.id)] = session end
	return result
end

-- `bindings` lets a caller that checks many worktrees read the store once.
local function boundSession(path, sessions, bindings)
	local binding = (bindings or records("sessions"))[path]
	if binding then
		local session = sessions[tostring(binding.id)]
		if session and session.host == binding.host then return session end
	end
	return nil
end

local function activeWorktree(cx)
	local current = cx.sessions:current()
	for path, binding in records("sessions") do
		if binding.id == current.id and binding.host == current.host then
			local project = repoById(binding.project)
			if project then return project, { path = path } end
		end
	end
	return nil, nil
end

local function removing(path, jobs)
	for _, job in jobs or records("jobs") do
		if job.kind == "remove" and job.path == path then return true end
	end
	return false
end

-- Agent CLIs recognised in terminals, by program name.
local AGENTS = {
	omp = true, pi = true, claude = true, codex = true, opencode = true, gemini = true,
	aider = true, amp = true, ["cursor-agent"] = true, crush = true, goose = true,
}

-- The agent CLI a shell command line runs, if any, e.g. "omp", "cd x && claude",
-- "FOO=1 /usr/local/bin/codex --resume".
local function runsAgent(line)
	-- omp's /restart re-execs Tern's managed binary by full path, which has a
	-- space in it: ".../Application Support/Tern/omp/versions/18.20.0 --restore …".
	if string.find(line, "/omp/versions/", 1, true) then return "omp" end
	for segment in string.gmatch(line, "[^;&|]+") do
		for word in string.gmatch(segment, "%S+") do
			if not string.find(word, "=", 1, true) then
				local program = string.match(word, "([^/]+)$")
				if AGENTS[program] then return program end
				break
			end
		end
	end
	return nil
end
assert(runsAgent("/Users/j/Library/Application Support/Tern/omp/versions/18.20.0 --restore /x.jsonl") == "omp"
	and runsAgent("FOO=1 /usr/local/bin/codex --resume") == "codex" and runsAgent("ls -la") == nil, "runsAgent self-check")

-- Native agent blocks' states by pane id: "working", or "waiting" (it asked
-- you something). Tern's agent_state events update it at once. The tick
-- resyncs from cx.agents:list() only every 30 s, for events a paused hook
-- missed: the call takes 7 to 20 ms (it carries every agent's last reply),
-- enough to push a tick past its budget (from upstream 2.4.3).
local AGENT_STATES = { working = "working", waiting_input = "waiting" }
local agentStates = {}
-- Agents whose turn ended while their tab wasn't shown: they wait for you
-- until you look at that tab. Tern reports them idle.
local unseen = {}
local function setAgentState(cx, pane, state)
	if state == "idle" and agentStates[pane] ~= nil then
		local focused = cx.session:focused()
		local tab = cx.session:tab_of(pane)
		if not (focused and tab and cx.session:tab_of(focused) == tab) then unseen[pane] = true end
	elseif state ~= "idle" then
		unseen[pane] = nil
	end
	agentStates[pane] = AGENT_STATES[state]
end
local AGENT_RESYNC_MS = 30000
local agentsSyncedAt = -AGENT_RESYNC_MS
-- Agent blocks Tern lists as running an agent. Their pane can report a shell
-- as its program with no command line (omp re-exec'd by /restart), so this,
-- not the program name, says an agent block is live.
local liveAgents = {}
local function syncAgents(cx)
	if tern.now() - agentsSyncedAt < AGENT_RESYNC_MS then return end
	agentsSyncedAt = tern.now()
	local live = {}
	for _, agent in cx.agents:list() do
		setAgentState(cx, agent.pane, agent.state)
		if agent.state ~= "exited" then live[agent.pane] = true end
	end
	liveAgents = live
end

local HOME = tern.getenv("HOME") or ""

local function expandHome(path)
	if string.sub(path, 1, 1) == "~" then return HOME .. string.sub(path, 2) end
	return path
end

local function tildePath(path)
	if HOME ~= "" and (path == HOME or string.sub(path, 1, #HOME + 1) == HOME .. "/") then
		return "~" .. string.sub(path, #HOME + 1)
	end
	return path
end

local function basename(path)
	return string.match(path, "([^/]+)/*$") or path
end

-- The folder a space is open in: the working directory of the first terminal
-- (or agent) of its first tab, in split order.
local function spaceDir(cx, info, panesById)
	local tab = info.tabs[1]
	local layout = tab and cx.session:layout(tab)
	if not layout then return nil end
	local found
	local function visit(tree)
		if found or not tree then return end
		if tree.pane then
			local pane = panesById[tree.pane]
			if pane and (pane.kind == "terminal" or pane.kind == "agent") and pane.cwd and pane.cwd ~= "" then
				found = expandHome(pane.cwd)
			end
			return
		end
		visit(tree[1])
		visit(tree[2])
	end
	visit(layout.root)
	return found
end

-- Whether you named the session: Overseer remembers each session's name when
-- it first sees it (`auto-names`), and a space is named after its folder
-- until its session's name differs from that. Tern names new sessions with
-- random words, so there's no telling a default name from a chosen one.
local function namedByYou(info, autoNames)
	local seen = autoNames[tostring(info.id)]
	return seen ~= nil and info.name ~= seen
end

-- The worktree holding `dir`: the deepest one whose path contains it.
local function worktreeAt(worktrees, dir)
	local best
	for _, tree in worktrees or {} do
		if dir == tree.path or string.sub(dir, 1, #tree.path + 1) == tree.path .. "/" then
			if not best or #tree.path > #best.path then best = tree end
		end
	end
	return best
end

-- Running agents in this window, and agent activity per session id (as a
-- string). Native agent blocks report their state (agentStates). A block
-- counts while Tern lists it as running an agent (liveAgents) or its program
-- or command line is an agent CLI; a block whose agent exited back to its
-- shell drops out. Agent CLIs in plain terminals only
-- report progress, which Tern exposes as `busy` (a CLI that hasn't reported
-- progress yet counts as busy while it runs).
local function agentPanes(tabsById, panes)
	local agents, sessions = {}, {}
	for _, pane in panes do
		local tab = pane.tab and tabsById[pane.tab]
		if tab and pane.exited == nil then
			local state, program
			local line = pane.running and pane.running.line
			local cli = (line and runsAgent(line)) or (if AGENTS[pane.program or ""] then pane.program else nil)
			if pane.kind == "agent" and (cli or liveAgents[pane.pane]) then
				state, program = agentStates[pane.pane] or (if unseen[pane.pane] then "waiting" else "idle"), cli or "omp"
			elseif pane.kind == "terminal" and line then
				program = runsAgent(line)
				if program then state = if pane.busy then "working" else "idle" end
			end
			if state then
				table.insert(agents, { pane = pane.pane, tab = tab, state = state, program = program, title = pane.title })
				local key = tostring(tab.session)
				-- Waiting wins: it is the state that needs you.
				if state ~= "idle" and sessions[key] ~= "waiting" then sessions[key] = state end
			end
		end
	end
	return agents, sessions
end

-- Returns the panel's model and the folders whose repository isn't known yet.
local function model(cx)
	local sessions = sessionsById(cx)
	local names, bindings, jobs = records("worktree-names"), records("sessions"), records("jobs")
	local autoNames = records("auto-names")
	-- One read of the window's tabs and panes serves the whole draw.
	local tabs, panes = cx.session:tabs(), cx.session:panes()
	local tabsById, panesById = {}, {}
	for _, tab in tabs do tabsById[tab.id] = tab end
	for _, pane in panes do panesById[pane.pane] = pane end
	local agents, activity = agentPanes(tabsById, panes)
	local current = cx.sessions:current()
	local pending, renames = {}, {}
	-- Creations in progress, by repository and branch. Elapsed time moves in
	-- 5 s steps, so the panel redraws for it only that often.
	local creating = {}
	for id, job in jobs do
		if job.kind == "create" and job.branch and job.project then
			local state = creationProgress[id] or {}
			creating[job.project] = creating[job.project] or {}
			creating[job.project][job.branch] = {
				pane = job.pane, label = job.displayName or job.branch, step = state.step,
				elapsed = math.max(0, os.time() - (job.started or os.time())) // 5 * 5,
				needsYou = state.needsYou == true, asking = state.asking == true,
				quiet = state.quiet and state.quiet // 5 * 5,
			}
		end
	end

	-- Every session is a space, named by you or else after its folder. Goal
	-- sessions are left out (they show under Goals), and so is Mission
	-- control's own session (the button at the top).
	local spaces, byId, missionActive = {}, {}, false
	local sessionNames = {}
	for index, info in cx.session:sessions() do
		sessionNames[tostring(info.id)] = info.name
		if mission.state.isGoalSession(info.id) then continue end
		if info.name == MISSION_SESSION then
			missionActive = info.id == current.id
			continue
		end
		local dir = spaceDir(cx, info, panesById)
		local repo = if dir then dirRepo[dir] else nil
		if dir and repo == nil then pending[dir] = true end
		local entry = if repo then cache[repo] else nil
		local named = namedByYou(info, autoNames)
		local space = {
			id = info.id, index = index, dir = dir, repo = repo or nil, named = named, sessionName = info.name,
			name = if named or not dir then info.name else basename(dir),
			tree = if entry and dir then worktreeAt(entry.worktrees, dir) else nil,
			agent = activity[tostring(info.id)], active = info.id == current.id,
		}
		table.insert(spaces, space)
		byId[info.id] = space
	end

	-- A repository's worktrees nest under one space open in it: the one in its
	-- primary checkout, else the first. Spaces open in its other worktrees
	-- appear as those rows instead of standing alone.
	local anchors = {}
	for _, space in spaces do
		if space.repo and space.tree and space.tree.is_main and not anchors[space.repo] then anchors[space.repo] = space end
	end
	for _, space in spaces do
		if space.repo and not anchors[space.repo] then anchors[space.repo] = space end
	end
	local nested = {}
	for repoId, anchor in anchors do
		local entry = cache[repoId]
		local repo = repoById(repoId)
		local rows = {}
		for _, worktree in (entry and entry.worktrees or {}) do
			-- Goal workers' worktrees belong to their goal (Goals, Mission control), not Spaces.
			if not (anchor.tree and anchor.tree.path == worktree.path) and not mission.workers.isWorkerBranch(worktree.branch) then
				local session = boundSession(worktree.path, sessions, bindings)
				local space = session and byId[session.id]
				if not space then
					for _, other in spaces do
						if other ~= anchor and other.repo == repoId and not nested[other.id]
							and other.tree and other.tree.path == worktree.path then
							space = other
							break
						end
					end
				end
				if space == anchor then space = nil end
				if space then
					nested[space.id] = true
					-- Worktree sessions read "repo / branch" in Tern's session list,
					-- unless you named them.
					local wanted = repo and worktree.branch and repo.name .. " / " .. worktree.branch
					if wanted and not space.named and space.sessionName ~= wanted then renames[space.id] = wanted end
				end
				local sessionId = (space and space.id) or (session and session.id)
				local item = table.clone(worktree)
				item.deleting = removing(worktree.path, jobs)
				item.label = (names[repoId] and names[repoId][worktree.path])
					or (space and space.named and space.name) or worktree.branch or basename(worktree.path)
				-- Its agents go by the name its row shows.
				if space then space.label = item.label end
				item.pr = worktree.branch and entry.prs and entry.prs[worktree.branch] or nil
				item.session, item.sessionId = sessionId ~= nil, sessionId
				item.agent = sessionId and activity[tostring(sessionId)]
				item.active = sessionId ~= nil and sessionId == current.id
				item.creating = worktree.branch and creating[repoId] and creating[repoId][worktree.branch] or nil
				if item.creating then item.creating.listed = true end
				table.insert(rows, item)
			end
		end
		-- A creation Worktrunk hasn't listed yet gets its row right away, first.
		local unlisted = {}
		for branch, state in (creating[repoId] or {}) do
			if not state.listed then
				table.insert(unlisted, { path = "creating:" .. branch, branch = branch, label = state.label, creating = state })
			end
		end
		table.sort(unlisted, function(a, b) return a.branch < b.branch end)
		for index, item in unlisted do table.insert(rows, index, item) end
		anchor.worktrees, anchor.base = rows, repo and repo.base
		anchor.error, anchor.collapsed = entry and entry.error, collapsed[repoId] == true
	end

	local result = { spaces = {}, agents = {}, refreshing = spinning, missionActive = missionActive }
	for _, space in spaces do
		if not nested[space.id] then
			-- Its session goes by the name the sidebar shows, unless you named it.
			if not space.named and space.dir and space.sessionName ~= space.name then renames[space.id] = space.name end
			local branch = space.tree and (space.tree.branch or "detached")
			-- The PR of the branch the space is on, as worktree rows show theirs.
			local prs = space.repo and cache[space.repo] and cache[space.repo].prs
			local pr = prs and space.tree and space.tree.branch and prs[space.tree.branch] or nil
			table.insert(result.spaces, {
				id = space.id, name = space.name, repo = space.repo, base = space.base,
				subtitle = branch or (space.dir and tildePath(space.dir)) or "",
				title = (space.dir or "No folder yet") .. (if branch then "\n" .. branch else ""),
				dirty = space.tree ~= nil and space.tree.dirty, agent = space.agent, session = true,
				active = space.active, worktrees = space.worktrees or {},
				collapsed = space.collapsed, error = space.error, pr = pr,
			})
		end
	end

	-- Agents keep their place, in space and tab order, as their state changes.
	local focused = cx.session:focused()
	local shown = focused and cx.session:tab_of(focused)
	table.sort(agents, function(a, b)
		local left, right = byId[a.tab.session], byId[b.tab.session]
		local li, ri = left and left.index or math.huge, right and right.index or math.huge
		if li ~= ri then return li < ri end
		if a.tab.position ~= b.tab.position then return a.tab.position < b.tab.position end
		return a.pane < b.pane
	end)
	-- Mission control: what needs you, goals with their tasks, each agent's task.
	local ms = mission.state.get()
	local agentByPane = {}
	for _, agent in agents do agentByPane[tostring(agent.pane)] = agent end
	local sessionOfPane = {}
	for session, pane in mission.sessionPanes do sessionOfPane[pane] = session end
	result.needsYou = #ms.waiting
	result.goals = {}
	local URGENCY = { waiting = 3, working = 2, idle = 1 }
	for _, g in ms.goals do
		if g.status == "active" or g.status == "finished" then
			-- Goal sessions read "G3 · title" (renamed when references or titles change).
			local goalName = g.ref .. " · " .. g.title
			if g.tern_session and sessionNames[g.tern_session] and sessionNames[g.tern_session] ~= goalName then
				renames[tonumber(g.tern_session)] = goalName
			end
			local goal = { ref = g.ref, title = g.title, session = g.tern_session, progress = g.progress or { done = 0, total = 0 },
				finished = g.status == "finished",
				needsYou = 0, dot = nil, tasks = {}, collapsed = collapsed["goal:" .. g.ref] == true }
			for _, w in ms.waiting do if w.goal == g.ref then goal.needsYou += 1 end end
			for _, t in ms.tasks do
				if t.goal == g.id then
					local pane = t.session and mission.sessionPanes[t.session]
					local agent = pane and agentByPane[pane]
					-- A finished task's agent may linger idle; show the task's status instead.
					local state = if agent and t.status == "doing" then agent.state else nil
					if state and (not goal.dot or URGENCY[state] > URGENCY[goal.dot]) then goal.dot = state end
					-- The coordinator's own task colours the goal's dot but isn't listed; its pane is where the goal opens.
					if t.session ~= nil and t.session == g.coordinator then goal.coordinatorPane = pane end
					if t.session == nil or t.session ~= g.coordinator then
						table.insert(goal.tasks, { ref = t.ref, title = t.title, status = t.status, state = state, pane = pane })
					end
				end
			end
			if goal.needsYou > 0 then goal.dot = "waiting" end
			table.insert(result.goals, goal)
		end
	end
	for _, agent in agents do
		-- Agents in goal sessions show under their goal instead.
		if not mission.state.isGoalSession(agent.tab.session) then
			local space = byId[agent.tab.session]
			local session = sessionOfPane[tostring(agent.pane)]
			local task = session and mission.state.taskOf(session)
			table.insert(result.agents, {
				pane = agent.pane, state = agent.state, program = agent.program, title = agent.title,
				name = if agent.tab.name and agent.tab.name ~= "" then agent.tab.name elseif space then space.label or space.name else "Agent",
				active = agent.tab.id == shown,
				task = task and { ref = task.ref, title = task.title },
			})
		end
	end
	return result, pending, renames
end

local NAVIGATOR = {
	title = "Spaces", about = "Your Tern sessions as spaces, their Git worktrees, and every running agent.",
}

-- Overseer also owns PR outline canvases; only navigators show Spaces. Before
-- 3.0 the navigator was titled Projects; a reload adopts one left open.
local function isNavigator(canvas)
	return canvas.owner == "overseer" and (canvas.title == NAVIGATOR.title or canvas.title == "Projects")
end

-- The window's one Spaces slot: the navigator canvas, or a form shown in its
-- place. Adopts what a reload (or an older, per-session version) left open and
-- closes any extra, so a window never shows two.
local slotPane = nil
local function slot(cx)
	if slotPane and not cx.session:pane(slotPane) then slotPane = nil end
	local found = {}
	for _, pane in cx.session:panes() do
		if pane.block == "overseer.form" then table.insert(found, pane.pane) end
	end
	for _, canvas in cx.canvas:list() do
		if isNavigator(canvas) and cx.session:pane(canvas.pane) then table.insert(found, canvas.pane) end
	end
	slotPane = slotPane or found[1]
	for _, pane in found do
		if pane ~= slotPane then
			cx.layout:close(pane)
			rendered[pane] = nil
		end
	end
	if not slotPane then return nil end
	local info = cx.session:pane(slotPane)
	return slotPane, if info and info.block == "overseer.form" then "form" else "canvas"
end

-- Defined after refresh: looks up the repositories of newly seen folders.
local inspectDirs

-- Renames worktree sessions to "repo / branch" (see model), in a callback of
-- its own. The new name is remembered as one you didn't choose. A session Tern
-- won't rename isn't tried again until the plugin reloads.
local renameRefused = {}
local function nameWorktreeSessions(renames)
	tern.timer(0, function(cx)
		if not cx then return end
		local autoNames = records("auto-names")
		for id, name in renames do
			if not renameRefused[id] then
				local ok, why = cx.layout:rename_session(id, name)
				if ok then
					autoNames[tostring(id)] = name
				else
					renameRefused[id] = true
					tern.log.warn("Overseer: couldn't rename session " .. tostring(id) .. ": " .. tostring(why))
				end
			end
		end
		tern.kv.set("auto-names", autoNames)
	end)
end

local function draw(cx)
	local pane, kind = slot(cx)
	if not pane or kind ~= "canvas" then return end
	-- A just-opened canvas only accepts updates once canvas:list() reports it.
	local ready = false
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then ready = true end
	end
	if not ready then return end
	local data, pending, renames = model(cx)
	if next(pending) then inspectDirs(pending) end
	if next(renames) then nameWorktreeSessions(renames) end
	local signature = tern.json.encode(data)
	if rendered[pane] == signature then return end
	local main, dock = view.render(data)
	cx.canvas:set(pane, { view = main, dock = dock })
	rendered[pane] = signature
end

-- Asks for a draw soon, in a timer callback of its own. Tern pauses a hook
-- that runs over its 50 ms of Lua, so clicks and process results never draw
-- inline; requests made before the draw runs share it.
local drawQueued = false
local function redraw(_cx)
	if drawQueued then return end
	drawQueued = true
	tern.timer(0, function(cx)
		drawQueued = false
		if not cx then return end
		local ok, err = pcall(draw, cx)
		if not ok and problem ~= tostring(err) then report(cx, err) end
	end)
end
-- A new Mission control state redraws the sidebar (Goals, Needs you, agents' tasks).
missionHooks.changed = redraw

local PR_REFRESH_MS = 120000

-- Pull request badges are best-effort: without gh, GitHub access, or a GitHub
-- origin they simply don't appear. Stale results stay visible until a lookup
-- succeeds again.
local function refreshPullRequests(project, entry)
	local branches = {}
	-- Every checked-out branch but the base, the primary checkout's included:
	-- a space can work on a feature branch without a worktree.
	for _, tree in entry.worktrees do
		if tree.branch and tree.branch ~= project.base then table.insert(branches, tree.branch) end
	end
	table.sort(branches)
	local key = table.concat(branches, "\0")
	if entry.prLoading then return end
	if key == entry.prKey and entry.prAt and tern.now() - entry.prAt < PR_REFRESH_MS then return end
	entry.prLoading = true
	wt.pull_requests(project, branches, function(found, err, cx)
		entry.prLoading, entry.prAt = false, tern.now()
		if found then
			entry.prs, entry.prKey, entry.prError = found, key, nil
		elseif err ~= entry.prError then
			entry.prError = err
			tern.log.warn("Pull requests unavailable for " .. project.name .. ": " .. tostring(err))
		end
		if cx then redraw(cx) end
	end)
end

-- `done(cx)` runs once the listing finishes. Returns false, never calling
-- `done`, while a listing of the repository is already running.
local function listRepo(repo, done)
	local entry = cache[repo.id]
	if not entry then
		entry = { worktrees = {} }
		cache[repo.id] = entry
	end
	if entry.loading then return false end
	entry.loading = true
	wt.list(repo, function(worktrees, err, nextCx)
		entry.loading, entry.error = false, err
		if worktrees then entry.worktrees = worktrees end
		if done then done(nextCx) end
		if nextCx then redraw(nextCx) end
		if worktrees then refreshPullRequests(repo, entry) end
	end)
	return true
end

-- `done` runs once every worktree listing this call started has finished.
local function refresh(cx, done)
	lastRefresh = tern.now()
	local pending = 0
	for id in repos do
		local started = listRepo(repoById(id), function(nextCx)
			pending -= 1
			if pending == 0 and done and nextCx then done(nextCx) end
		end)
		if started then pending += 1 end
	end
	if pending == 0 and done then done(cx) end
	redraw(cx)
end

-- Finds which repository each folder is in; a repository seen for the first
-- time is listed right away.
inspectDirs = function(dirs)
	for dir in dirs do
		if not inspecting[dir] then
			inspecting[dir] = true
			wt.inspect(dir, function(repo, err, cx, notRepo)
				inspecting[dir] = nil
				if repo then
					dirRepo[dir] = repo.id
					if not repos[repo.id] then
						repos[repo.id] = repo
						listRepo(repoById(repo.id))
					end
				else
					dirRepo[dir] = false
					if not notRepo then tern.log.warn("Overseer: no repository for " .. dir .. ": " .. tostring(err)) end
				end
				if cx then redraw(cx) end
			end)
		end
	end
end

-- ↻ spins from an explicit refresh until its worktree listings finish, and
-- for at least one turn so a fast refresh is still visible.
local SPIN_MIN_MS = 800

local function refreshByHand(cx)
	if spinning then return end
	spinning = true
	local started = tern.now()
	-- An explicit refresh also re-checks pull requests immediately, and folders
	-- that weren't repositories (one may have been initialised since).
	for _, entry in cache do entry.prAt = nil end
	for dir, repo in dirRepo do
		if repo == false then dirRepo[dir] = nil end
	end
	refresh(cx, function(doneCx)
		local function stop(stopCx)
			spinning = false
			if stopCx then redraw(stopCx) end
		end
		local left = started + SPIN_MIN_MS - tern.now()
		if left > 0 then tern.timer(left, stop) else stop(doneCx) end
	end)
end

-- Tern panes belong to one tab, so the window's one Spaces panel follows you:
-- whenever another tab is shown, it moves there, full height on the left.
local DEFAULT_SHARE = 0.3
-- The width you leave it at travels with it (a share of the tab).
local share = tonumber(tern.kv.get("panel-share")) or DEFAULT_SHARE
-- Whether you want the panel shown; it reopens after vanishing with its tab.
local wantPanel = tern.kv.get("panel-open") == true
-- The tab the panel was last placed in, to tell a closed panel from a closed tab.
local panelTab = nil

local function firstLeaf(tree, skip)
	if not tree then return nil end
	if tree.pane then return if tree.pane == skip then nil else tree.pane end
	return firstLeaf(tree[1], skip) or firstLeaf(tree[2], skip)
end

-- Whether `tree` contains `pane`.
local function hasPane(tree, pane)
	if not tree then return false end
	if tree.pane then return tree.pane == pane end
	return hasPane(tree[1], pane) or hasPane(tree[2], pane)
end

-- The panel's share of the tab's width while it is the leftmost pane, however
-- deeply the tab's splits nest it (from upstream 2.4.2). Each "right" split it
-- sits left of multiplies the share; "down" splits don't change its width. A
-- pane that isn't on the left edge returns nil, so pin still moves it there.
local function leftShare(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local node = layout and layout.root
	local share = 1
	while node and not node.pane do
		if node.split == "right" then
			if not hasPane(node[1], pane) then return nil end
			share = share * node.ratio
			node = node[1]
		elseif hasPane(node[1], pane) then
			node = node[1]
		else
			node = node[2]
		end
	end
	if node and node.pane == pane then return share end
	return nil
end

-- The tree with `pane` taken out, its parent split collapsing as Tern's would.
local function without(tree, pane)
	if tree.pane then return if tree.pane == pane then nil else tree end
	local a, b = without(tree[1], pane), without(tree[2], pane)
	if not a then return b end
	if not b then return a end
	return { split = tree.split, ratio = tree.ratio, a, b }
end

local function nodeAt(tree, path)
	for _, i in path do tree = tree and tree[i] end
	return tree
end

-- The leaf of `tree` touching its far edge toward `dir`: growing it toward
-- `dir` moves the divider just past that edge.
local function edgeLeaf(tree, dir)
	if tree.pane then return tree.pane end
	return edgeLeaf(if tree.split == dir then tree[2] else tree[1], dir)
end

-- Sets the ratio of the split at `path` by growing `leaf` toward `dir`.
-- Tern resizes in cells, and a hidden tab's cells differ from the shown one's,
-- so steer by the ratio: step, see how far it moved, correct.
local function steer(cx, tab, path, leaf, dir, want)
	local function ratio()
		local layout = cx.session:layout(tab)
		local node = layout and nodeAt(layout.root, path)
		return node and node.split == dir and node.ratio or nil
	end
	local r = ratio()
	local step = if r then math.floor((want - r) * (if dir == "right" then 180 else 50) + 0.5) else 0
	for _ = 1, 8 do
		if not r or math.abs(r - want) < 0.005 or step == 0 then return end
		cx.layout:resize(leaf, dir, step)
		local after = ratio()
		if not after or after == r then return end
		step = math.floor((want - after) * step / (after - r) + 0.5)
		r = after
	end
end

-- Tern only moves a pane beside another pane, never beside a whole split, so
-- `tree`'s panes are dealt back in beside the first one, which starts out
-- holding all of `tree`'s area: each split's second side splits off its first.
local function rebuild(cx, tree)
	if tree.pane then return end
	cx.layout:move(firstLeaf(tree[2]), firstLeaf(tree[1]), tree.split, { focus = false })
	rebuild(cx, tree[1])
	rebuild(cx, tree[2])
end

-- Gives each split of `tree`, now at `path` in `tab`, its ratio from before.
local function restoreRatios(cx, tab, tree, path)
	if tree.pane then return end
	steer(cx, tab, path, edgeLeaf(tree[1], tree.split), tree.split, tree.ratio)
	local first, second = table.clone(path), table.clone(path)
	table.insert(first, 1)
	table.insert(second, 2)
	restoreRatios(cx, tab, tree[1], first)
	restoreRatios(cx, tab, tree[2], second)
end

-- Moves the slot into `tab` as its full-height left column, unless it is
-- already there. Moving it beside the first pane alone would put it beside
-- only the top half of a top/bottom split, so the rest of the tab is rebuilt
-- to its right with the same splits and ratios.
local function pin(cx, tab)
	local pane = slot(cx)
	if not pane then return end
	local layout = cx.session:layout(tab)
	if not layout then return end
	local from = cx.session:tab_of(pane)
	if from == tab and leftShare(cx, tab, pane) then
		panelTab = tab
		return
	end
	local rest = without(layout.root, pane)
	if not rest then return end
	if from then
		local current = leftShare(cx, from, pane)
		if current and math.abs(current - share) > 0.01 then
			share = math.clamp(current, 0.15, 0.6)
			tern.kv.set("panel-share", share)
		end
	end
	if from ~= tab then
		if from then
			cx.layout:move_to_tab(pane, tab, { focus = false })
		else
			cx.layout:unpark(pane, { focus = false })
		end
	end
	cx.layout:move(pane, firstLeaf(rest), "left", { focus = false })
	rebuild(cx, rest)
	restoreRatios(cx, tab, rest, { 2 })
	steer(cx, tab, {}, pane, "right", share)
	panelTab = tab
end

local function shownTab(cx)
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

local function setWantPanel(want)
	wantPanel = want
	tern.kv.set("panel-open", want)
end

-- Opens a fresh navigator in `tab`.
local function openPanel(cx, tab)
	local data = model(cx)
	local main, dock = view.render(data)
	local pane, err = cx.canvas:open({
		title = NAVIGATOR.title, about = NAVIGATOR.about,
		view = main, dock = dock, how = "beside", focus = false,
	})
	if not pane then report(cx, err or "Could not open the Spaces panel"); return nil end
	slotPane = pane
	rendered[pane] = tern.json.encode(data)
	if tab then pin(cx, tab) end
	return pane
end

-- Keeps the panel in the shown tab. Runs on every tab, pane and focus event and
-- each tick, so one paused hook can't leave it behind.
local function follow(cx, tab)
	if not localHost(cx) then return end
	tab = tab or shownTab(cx)
	if not tab then return end
	local pane = slot(cx)
	if not pane then
		if not wantPanel then return end
		-- Gone while its tab remains: you closed it. Gone with its tab (a closed
		-- session or tab): bring it back here.
		local tabStillOpen = false
		for _, info in cx.session:tabs() do
			if info.id == panelTab then tabStillOpen = true end
		end
		if tabStillOpen then
			setWantPanel(false)
			panelTab = nil
			return
		end
		openPanel(cx, tab)
		return
	end
	-- Alone in the shown tab: its last terminal just closed. Close the tab as
	-- Tern would have; the tab shown next takes the panel.
	local layout = cx.session:tab_of(pane) == tab and cx.session:layout(tab)
	if layout and not firstLeaf(layout.root, pane) then
		cx.layout:park(pane)
		return
	end
	-- A panel already open (for example, from before an update) is one you want.
	if not wantPanel then setWantPanel(true) end
	pin(cx, tab)
end

-- Swaps `slot` for a new pane in the same place and size: Tern has no in-place
-- replace for canvases, so open the new pane beside the old one (splitting only
-- that slot), then close the old one so the new pane inherits the whole slot.
local function swapSlot(cx, old, open)
	cx.layout:focus(old)
	local pane, err = open()
	if not pane then return nil, err end
	cx.layout:close(old)
	rendered[old] = nil
	slotPane = pane
	return pane
end

-- Shows the Spaces panel in the shown tab and focuses it, opening it if needed.
local function navigator(cx)
	if not requireLocal(cx) then return nil end
	setWantPanel(true)
	local tab = shownTab(cx)
	local pane = slot(cx)
	if pane then
		if tab then pin(cx, tab) end
	else
		pane = openPanel(cx, tab)
		if not pane then return nil end
	end
	cx.layout:focus(pane)
	refresh(cx)
	return pane
end

-- The Spaces shortcut: hides the panel when it has focus, otherwise shows and focuses it.
local function togglePanel(cx)
	if not requireLocal(cx) then return end
	local pane, kind = slot(cx)
	if pane and kind == "canvas" and cx.session:focused() == pane then
		setWantPanel(false)
		cx.layout:close(pane)
		rendered[pane] = nil
		slotPane, panelTab = nil, nil
		return
	end
	navigator(cx)
end

local function findWorktree(path)
	for id, entry in cache do
		for _, worktree in entry.worktrees or {} do
			if worktree.path == path then return repoById(id), worktree end
		end
	end
	return nil, nil
end

-- Opens a space in `dir`. Its session is called `name` (default the folder's
-- name), remembered as a name you didn't choose.
local function createSpace(cx, dir, name)
	name = name or basename(dir)
	local session = cx.sessions:create({ name = name, cwd = dir })
	local autoNames = records("auto-names")
	autoNames[tostring(session.id)] = name
	tern.kv.set("auto-names", autoNames)
	return session
end

-- The session open in a worktree: the one bound to it, else a space whose
-- folder is in it, which is then bound.
local function worktreeSession(cx, path)
	local sessions = sessionsById(cx)
	local session = boundSession(path, sessions)
	if session then return session end
	local repo = findWorktree(path)
	local entry = repo and cache[repo.id]
	if not entry then return nil end
	local panesById = {}
	for _, pane in cx.session:panes() do panesById[pane.pane] = pane end
	for _, info in cx.session:sessions() do
		local dir = spaceDir(cx, info, panesById)
		local tree = dir and worktreeAt(entry.worktrees, dir)
		local found = tree and tree.path == path and sessions[tostring(info.id)]
		if found then
			local bindings = records("sessions")
			bindings[path] = { id = found.id, host = found.host, project = repo.id }
			tern.kv.set("sessions", bindings)
			return found
		end
	end
	return nil
end

-- Shows the worktree's session, opening and binding one when it has none.
-- The panel follows into it (see follow).
local function ensureSession(cx, project, path, branch)
	local session = worktreeSession(cx, path)
	if session then
		cx.sessions:switch(session.id)
	else
		session = createSpace(cx, path, if branch then project.name .. " / " .. branch else nil)
		local bindings = records("sessions")
		bindings[path] = { id = session.id, host = session.host, project = project.id }
		tern.kv.set("sessions", bindings)
	end
	follow(cx)
end

local function openWorktree(cx, path)
	if not requireLocal(cx) then return end
	if removing(path) then report(cx, "Check the Delete tab.", "Deletion in progress"); return end
	local project, worktree = findWorktree(path)
	if not project then report(cx, "Worktree not found. Refresh Spaces."); return end
	if not tern.fs.exists(path) then report(cx, "Worktree directory is missing: " .. path, "Worktree unavailable"); refresh(cx); return end
	ensureSession(cx, project, path, worktree.branch)
	redraw(cx)
end

local function token()
	sequence += 1
	return tostring(os.time()) .. "-" .. tostring(math.floor(tern.now() * 1000)) .. "-" .. tostring(math.random(1, 1000000000)) .. "-" .. tostring(sequence)
end

-- A session that can't close: locked, or holding a running worktree operation.
local function sessionGuard(cx, session)
	if session.locked then return "Unlock the session first." end
	local tabs = {}
	for _, tab in cx.session:tabs() do tabs[tab.id] = tab.session end
	for _, job in records("jobs") do
		local tab = cx.session:tab_of(job.pane)
		if tab and tabs[tab] == session.id then
			return "Finish or cancel the running operation."
		end
	end
	return nil
end

local function closeGuard(cx, path)
	local session = worktreeSession(cx, path)
	if not session then return nil, nil end
	local err = sessionGuard(cx, session)
	if err then return nil, err end
	return session, nil
end

local function closeManagedSession(cx, path, expected)
	local bindings = records("sessions")
	local binding = bindings[path]
	if not binding then return true end
	if expected and (binding.id ~= expected.id or binding.host ~= expected.host) then return true end
	local session, err = closeGuard(cx, path)
	if err then return false, err end
	if session then
		if cx.sessions:current().id == session.id then
			-- Land in the repository's primary checkout session when it's open (it
			-- also holds a deletion's output tab); otherwise any other session.
			local replacement
			local project = repoById(binding.project)
			local primary = project and bindings[project.path]
			for _, other in cx.sessions:list() do
				if other.id ~= session.id and other.host == session.host then
					if primary and other.id == primary.id then replacement = other; break end
					replacement = replacement or other
				end
			end
			if replacement then
				cx.sessions:switch(replacement.id)
			else
				createSpace(cx, if project then project.path else HOME)
			end
		end
		-- The panel lives in the shown tab: take it into the session shown now,
		-- or it closes with this one.
		follow(cx)
		cx.sessions:close(session.id)
	end
	bindings[path] = nil
	tern.kv.set("sessions", bindings)
	return true
end

-- Confirmations open in a canvas of their own over the tab (`how = "glimpse"`),
-- which closes at the next click outside it: that counts as Cancel (see
-- pane_closed). Asking again replaces an open one.
local function endConfirmation(cx)
	local request = confirmation
	confirmation = nil
	if request and request.pane and cx.session:pane(request.pane) then cx.layout:close(request.pane) end
end

local function showConfirmation(cx, request)
	endConfirmation(cx)
	local words = view.confirmationWords(request)
	local pane, err = cx.canvas:open({
		title = words.title,
		about = "Overseer asks before it runs " .. words.confirm .. " on " .. request.label .. ". Cancel or a click outside keeps it.",
		view = view.confirmation(request), how = "glimpse",
	})
	if not pane then report(cx, err or "Could not open the confirmation."); return end
	request.pane = pane
	confirmation = request
end

-- Redraws the open confirmation after its request changed (checking, or the
-- uncommitted changes a Force delete would lose).
local function updateConfirmation(cx)
	local request = confirmation
	if not request or not request.pane then return end
	local ok, err = pcall(function()
		cx.canvas:set(request.pane, { title = view.confirmationWords(request).title, view = view.confirmation(request) })
	end)
	if not ok then tern.log.warn("Overseer: confirmation not updated: " .. tostring(err)) end
end

local function requestWorktreeAction(cx, kind, path)
	local project, worktree = findWorktree(path)
	if not project then report(cx, "Worktree not found. Refresh Spaces."); return end
	if removing(path) then report(cx, "This worktree is already being deleted."); return end
	local session, err = closeGuard(cx, path)
	if err then report(cx, err); return end
	if kind == "close" and not session then report(cx, "This worktree has no open session."); return end
	if kind == "delete" and (worktree.is_main or path == project.path) then
		report(cx, "The primary checkout cannot be deleted."); return
	end
	showConfirmation(cx, {
		id = token(), kind = kind, path = path, label = worktree.branch or "Detached HEAD",
		project = project.id, worktree = table.clone(worktree),
	})
end

-- A space as its menu actions need it: {id, name, named, folder, dir, repo}.
local function spaceInfo(cx, id)
	local panesById = {}
	for _, pane in cx.session:panes() do panesById[pane.pane] = pane end
	for _, info in cx.session:sessions() do
		if info.id == id then
			local dir = spaceDir(cx, info, panesById)
			local named = namedByYou(info, records("auto-names"))
			return {
				id = id, dir = dir, named = named, folder = if dir then basename(dir) else info.name,
				name = if named or not dir then info.name else basename(dir),
				repo = dir and dirRepo[dir] or nil,
			}
		end
	end
	return nil
end

-- Drops what Overseer remembers about a session that has ended.
local function forgetSession(id)
	local autoNames = records("auto-names")
	if autoNames[tostring(id)] ~= nil then
		autoNames[tostring(id)] = nil
		tern.kv.set("auto-names", autoNames)
	end
	local bindings, unbound = records("sessions"), false
	for path, binding in bindings do
		if binding.id == id then bindings[path], unbound = nil, true end
	end
	if unbound then tern.kv.set("sessions", bindings) end
end

-- Closes a space's session, showing another space first when it's the one
-- shown, so the panel moves out of it.
local function closeSpace(cx, id)
	local session = sessionsById(cx)[tostring(id)]
	if not session then return true end
	local err = sessionGuard(cx, session)
	if err then return false, err end
	if cx.sessions:current().id == id then
		for _, other in cx.sessions:list() do
			if other.id ~= id and other.host == session.host then
				cx.sessions:switch(other.id)
				break
			end
		end
	end
	follow(cx)
	cx.sessions:close(id)
	forgetSession(id)
	return true
end

local function requestSpaceClose(cx, id)
	local space = id and spaceInfo(cx, id)
	local session = space and sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Space not found. Refresh Spaces."); return end
	local err = sessionGuard(cx, session)
	if err then report(cx, err); return end
	showConfirmation(cx, { id = token(), kind = "space", space = id, label = space.name, path = space.dir })
end

-- Open PR outline canvases by "<project id>#<number>": asking again focuses the open one.
local outlines = {}

local function setOutline(cx, pane, md)
	local ok, err = pcall(function() cx.canvas:set(pane, { md = md }) end)
	if not ok then report(cx, err, "Visualize PR failed") end
end

-- A read-only outline of the worktree's pull request in a canvas tab. Nothing on
-- GitHub or in the checkout changes; see visualize.luau.
local function visualizePr(cx, path)
	local project, worktree = findWorktree(path)
	local entry = project and cache[project.id]
	local pr = entry and entry.prs and worktree.branch and entry.prs[worktree.branch]
	if not pr then report(cx, "No pull request found. Refresh Spaces."); return end
	local key = project.id .. "#" .. tostring(pr.number)
	if outlines[key] and cx.canvas:get(outlines[key]) then cx.layout:focus(outlines[key]); return end
	local heading = "# PR #" .. tostring(pr.number) .. "\n\n"
	local pane, err = cx.canvas:open({
		title = "PR #" .. tostring(pr.number) .. " · Visual outline",
		about = "Read-only visual outline of pull request #" .. tostring(pr.number) .. " (" .. pr.url
			.. "), drafted by omp from its diff. Nothing on GitHub changes.",
		md = heading .. "Reading the pull request and drafting its outline with omp. This usually takes a minute or two; nothing on GitHub changes.",
		how = "tab",
	})
	if not pane then report(cx, err or "Could not open a canvas.", "Visualize PR failed"); return end
	outlines[key] = pane
	visualize.outline(project, worktree, pr.number, function(md, outlineErr, nextCx)
		if not nextCx or not nextCx.canvas:get(pane) then return end
		if md then
			setOutline(nextCx, pane, md)
		else
			tern.log.warn("Visualize PR #" .. tostring(pr.number) .. " failed: " .. tostring(outlineErr))
			setOutline(nextCx, pane, heading .. "Couldn't draft the outline.\n\n```text\n" .. tostring(outlineErr) .. "\n```")
		end
	end)
end

-- A session to keep a removal's output tab in when the worktree being removed
-- is the current session: it closes on success, taking its tabs with it.
-- Prefers the project's primary checkout session, then any other session.
local function outputSession(cx, project, target)
	local sessions = sessionsById(cx)
	local primary = records("sessions")[project.path]
	if primary and primary.id ~= target.id and sessions[tostring(primary.id)] then return primary.id end
	for _, session in cx.sessions:list() do
		if session.id ~= target.id and session.host == target.host then return session.id end
	end
	return nil
end

local function confirmWorktreeAction(cx, id)
	local request = confirmation
	if not request or request.id ~= id or request.checking then return end
	if request.kind == "close" or request.kind == "space" then
		endConfirmation(cx)
		local ok, err
		if request.kind == "space" then ok, err = closeSpace(cx, request.space)
		else ok, err = closeManagedSession(cx, request.path) end
		if not ok then report(cx, err, "Session closure failed") else
			cx:toast("info", if request.kind == "space" then "Space closed" else "Session closed", notificationLabel(request.label))
		end
		redraw(cx)
		return
	end
	local project = repoById(request.project)
	if not project then endConfirmation(cx); report(cx, "Repository is no longer known. Refresh Spaces."); return end
	request.checking = true
	updateConfirmation(cx)
	-- Cancelling (or a click outside) or reloading while a check runs never starts a deletion.
	local function current(nextCx) return nextCx ~= nil and confirmation == request end
	local function failed(freshCx, text)
		endConfirmation(freshCx)
		report(freshCx, text, "Worktree deletion failed")
		refresh(freshCx)
	end
	local function launch(nextCx, worktree, force)
		local _, guardError = closeGuard(nextCx, request.path)
		if guardError then failed(nextCx, guardError); return end
		local jobs = records("jobs")
		for _, job in jobs do
			if job.project == project.id and (job.path == worktree.path or (worktree.branch and job.branch == worktree.branch)) then
				failed(nextCx, "A Worktrunk operation is already running for this worktree."); return
			end
		end
		local jobId = token()
		local receipt = tern.plugin.data .. "/removal-" .. jobId .. ".status"
		local ready, command = pcall(wt.removal_command, project, worktree, receipt, force)
		if not ready then failed(nextCx, command); return end
		-- Like creation, the output tab opens in the background; you stay put.
		local terminal = nextCx.layout:new_tab({ cwd = project.path, command = command }, { focus = false })
		if not terminal then failed(nextCx, "Could not open the removal terminal."); return end
		local target = records("sessions")[worktree.path]
		if target and nextCx.sessions:current().id == target.id then
			-- This session closes on success; keep the output somewhere that survives.
			local keep = outputSession(nextCx, project, target)
			if keep then nextCx.layout:move_to_new_tab(terminal, keep, { focus = false }) end
		end
		local tab = nextCx.session:tab_of(terminal)
		if tab then nextCx.layout:name_tab(tab, "Delete: " .. request.label) end
		jobs[jobId] = {
			kind = "remove", project = project.id, path = worktree.path, branch = worktree.branch,
			label = request.label, receipt = receipt, pane = terminal, started = os.time(),
			session = target,
		}
		tern.kv.set("jobs", jobs)
		oplog.write("info", { op = "remove", event = "started", project = project.name, branch = worktree.branch,
			path = worktree.path, detail = if force then "forced" else nil })
		endConfirmation(nextCx)
		nextCx:toast("info", "Deleting worktree", notificationLabel(request.label))
		redraw(nextCx)
	end
	-- A clean worktree goes straight away. With uncommitted changes, the popup
	-- lists them and offers Force delete, which comes back here with force set.
	wt.validate_removal(project, request.worktree, function(worktree, err, nextCx)
		if not current(nextCx) then return end
		if not worktree then failed(nextCx, err); return end
		if request.force then launch(nextCx, worktree, true); return end
		if not worktree.dirty and not worktree.status_unknown then launch(nextCx, worktree, false); return end
		wt.local_changes(worktree.path, function(changes, changesError, changesCx)
			if not current(changesCx) then return end
			if not changes then failed(changesCx, changesError); return end
			-- Clean again by now: the helper still refuses if that changes before it runs.
			if changes.total == 0 then launch(changesCx, worktree, false); return end
			request.worktree, request.changes, request.force, request.checking = table.clone(worktree), changes, true, false
			updateConfirmation(changesCx)
		end)
	end)
end

-- Forms take the Spaces panel's place, like a page within it, and follow you
-- the same way; finishing or going back puts the panel back. Rename space
-- passes `space` (see spaceInfo) instead of a repository.
local function openForm(cx, mode, project, worktree, space)
	if not requireLocal(cx) then return end
	if worktree and removing(worktree.path) then report(cx, "This worktree is being deleted."); return end
	local current, kind = slot(cx)
	if kind == "form" then
		cx.layout:focus(current)
		cx:toast("info", "Form already open", "Finish it or go back to Spaces.")
		return
	end
	if not current then
		-- Opening the panel and swapping it in one callback risks Tern's 50 ms budget.
		if not navigator(cx) then return end
		tern.timer(0, function(nextCx)
			if nextCx and slot(nextCx) then openForm(nextCx, mode, project, worktree, space) end
		end)
		return
	end
	local names = worktree and records("worktree-names")[project.id]
	local id = token()
	local args = if space then { id, mode, space.folder, if space.named then space.name else "" }
		else {
			id, mode,
			if worktree then worktree.branch or "Detached HEAD" else project and project.name or "",
			if worktree then names and names[worktree.path] or "" else project and project.base or "",
		}
	local pane = swapSlot(cx, current, function()
		return cx:new_block("overseer.form", args, "beside")
	end)
	if not pane then report(cx, "Reload the Overseer plugin.", "Form unavailable"); return end
	tern.kv.set("pending-form:" .. tostring(pane), {
		token = id, mode = mode, project = project and project.id, path = worktree and worktree.path,
		space = space and space.id,
	})
	watchForms()
end

local function rejectForm(cx, pane, err)
	inflight[pane] = nil
	local request = tern.kv.get("pending-form:" .. tostring(pane))
	if request then
		request.response = nil
		tern.kv.set("pending-form:" .. tostring(pane), request)
	end
	if cx.session:pane(pane) then
		cx.session:event(pane, { ev = "action", act = "retry", value = tostring(err) })
	else
		report(cx, err)
	end
end

local function finishForm(cx, pane)
	inflight[pane] = nil
	tern.kv.set("pending-form:" .. tostring(pane), nil)
	if not cx.session:pane(pane) then return end
	local data = model(cx)
	local navigatorPane = swapSlot(cx, pane, function()
		local main, dock = view.render(data)
		return cx.canvas:open({
			title = NAVIGATOR.title, about = NAVIGATOR.about, view = main, dock = dock, how = "beside",
		})
	end)
	if navigatorPane then
		rendered[navigatorPane] = tern.json.encode(data)
	else
		cx.layout:close(pane)
	end
end

-- AppleScript for macOS's native folder picker; the start folder arrives as an
-- argument, so no path is ever spliced into the script text.
local CHOOSE_FOLDER = {
	"on run argv",
	'POSIX path of (choose folder with prompt "Choose a folder for the new space" default location (POSIX file (item 1 of argv)))',
	"end run",
}

-- Where the picker starts: beside the last space's folder, else ~/code, else ~.
local function pickerStart()
	local last = tern.kv.get("picker-start")
	if type(last) == "string" and tern.fs.exists(last) then return last end
	local home = tern.getenv("HOME") or "/"
	if tern.fs.exists(home .. "/code") then return home .. "/code" end
	return home
end

local picking = false

-- Opens macOS's folder picker; the chosen folder opens as a new space.
local function pickSpace(cx)
	if not requireLocal(cx) then return end
	if picking then
		cx:toast("info", "Folder picker already open", "Choose a folder or cancel it.")
		return
	end
	picking = true
	local argv = { "/usr/bin/osascript" }
	for _, line in CHOOSE_FOLDER do
		table.insert(argv, "-e")
		table.insert(argv, line)
	end
	table.insert(argv, pickerStart())
	-- The picker waits for the user; give up after 30 minutes untouched.
	tern.process.run(argv, { timeout_ms = 30 * 60 * 1000 }, function(result, nextCx)
		picking = false
		if not nextCx then return end
		if result.status ~= 0 then
			-- Cancel (AppleScript error -128), timeouts, and pickers ended by a
			-- signal (status -1, e.g. a plugin reload) need no message.
			if result.status == -1 or string.find(result.stderr or "", "-128", 1, true) then return end
			report(nextCx, "Couldn't open the folder picker: " .. ((result.stderr or ""):match("^%s*(.-)%s*$")), "Folder picker failed")
			return
		end
		local path = (result.stdout or ""):match("^%s*(.-)%s*$")
		if #path > 1 then path = path:gsub("/+$", "") end
		tern.kv.set("picker-start", string.match(path, "^(.*)/[^/]+$") or path)
		createSpace(nextCx, path)
		follow(nextCx)
		redraw(nextCx)
	end)
end

-- Display names are single-line labels for the Spaces panel; blank means
-- "use the default".
local function normalizeName(raw)
	if raw == nil then return nil end
	if type(raw) ~= "string" or raw:find("[%c]") then
		return nil, "Use a single-line display name without control characters."
	end
	local name = raw:match("^%s*(.-)%s*$")
	return if name == "" then nil else name
end

-- Starts Worktrunk's creation of `job.branch` in a background tab and records
-- `job` for checkJobs. Returns an error message instead when it cannot start.
local function launchCreation(cx, project, job)
	for _, other in records("jobs") do
		if other.project == project.id and other.branch == job.branch then
			return "Creation is already running. Check its setup terminal."
		end
	end
	local id = token()
	local receipt = tern.plugin.data .. "/creation-" .. id .. ".status"
	local ready, command = pcall(wt.creation_command, project, job.branch, receipt)
	if not ready then return command end
	-- A background tab: the panel stays in front while setup runs.
	local terminal = cx.layout:new_tab({ cwd = project.path, command = command }, { focus = false })
	if not terminal then return "Could not open the creation terminal." end
	local tab = cx.session:tab_of(terminal)
	if tab then cx.layout:name_tab(tab, "Create: " .. job.branch) end
	job.kind, job.project, job.receipt, job.pane, job.started = "create", project.id, receipt, terminal, os.time()
	local jobs = records("jobs")
	jobs[id] = job
	tern.kv.set("jobs", jobs)
	oplog.write("info", { op = "create", event = "started", project = project.name, branch = job.branch })
	return nil
end

local function createWorktree(cx, pane, request, response)
	local project = repoById(request.project)
	if not project then rejectForm(cx, pane, "Repository is no longer known. Refresh Spaces."); return end
	if project.base == "" then rejectForm(cx, pane, "No base branch found. Check out a branch, then try again."); return end
	local displayName, nameError = normalizeName(response.name)
	if nameError then rejectForm(cx, pane, nameError); return end
	wt.validate(project, response.branch, function(ok, err, nextCx)
		if not nextCx then return end
		if not nextCx.session:pane(pane) then finishForm(nextCx, pane); return end
		if not ok then rejectForm(nextCx, pane, err); return end
		local launchError = launchCreation(nextCx, project, { branch = response.branch, displayName = displayName })
		if launchError then rejectForm(nextCx, pane, launchError); return end
		finishForm(nextCx, pane)
		nextCx:toast("info", "Creating worktree", notificationLabel(displayName or response.branch))
		redraw(nextCx)
	end)
end

local function renameWorktree(cx, pane, request, response)
	local project, worktree = findWorktree(request.path)
	if not project or project.id ~= request.project or not tern.fs.exists(request.path) then
		rejectForm(cx, pane, "Worktree is no longer available. Refresh Spaces."); return
	end
	if removing(request.path) then rejectForm(cx, pane, "This worktree is being deleted."); return end
	local name, nameError = normalizeName(response.name)
	if nameError then rejectForm(cx, pane, nameError); return end
	local names = records("worktree-names")
	names[project.id] = names[project.id] or {}
	names[project.id][worktree.path] = name
	tern.kv.set("worktree-names", names)
	finishForm(cx, pane)
	cx:toast("info", if name == nil then "Branch label restored" else "Worktree renamed",
		notificationLabel(name or worktree.branch or "Detached HEAD"))
	redraw(cx)
end

-- A space's name is its Tern session's name, shown once it differs from the
-- name Overseer first saw (see namedByYou). Clearing it names the space after
-- its folder again: the session keeps its name (Tern refuses a blank one),
-- remembered as one you didn't choose.
local function renameSpace(cx, pane, request, response)
	local session = sessionsById(cx)[tostring(request.space)]
	if not session then rejectForm(cx, pane, "This space has closed."); return end
	local name, nameError = normalizeName(response.name)
	if nameError then rejectForm(cx, pane, nameError); return end
	local autoNames, key = records("auto-names"), tostring(session.id)
	if name then
		local ok, why = cx.layout:rename_session(session.id, name)
		if not ok then rejectForm(cx, pane, why or "Could not rename the space."); return end
		if autoNames[key] == nil then autoNames[key] = session.name end
	else
		autoNames[key] = session.name
	end
	tern.kv.set("auto-names", autoNames)
	finishForm(cx, pane)
	cx:toast("info", if name then "Space renamed" else "Space named after its folder", notificationLabel(name or session.name))
	redraw(cx)
end

-- New worktrees branch from the repository's base; only an existing local branch is accepted.
local function changeBase(cx, pane, request, response)
	local project = repoById(request.project)
	if not project then rejectForm(cx, pane, "Repository is no longer known. Refresh Spaces."); return end
	local base = type(response.base) == "string" and response.base:match("^%s*(.-)%s*$") or ""
	if base == "" or base:find("[%c%s]") or base:sub(1, 1) == "-" then
		rejectForm(cx, pane, "Enter a local branch name, such as main."); return
	end
	tern.process.run({ "git", "-C", project.path, "show-ref", "--verify", "--quiet", "refs/heads/" .. base },
		{ timeout_ms = 15000 }, function(result, nextCx)
			if not nextCx then return end
			if not nextCx.session:pane(pane) then finishForm(nextCx, pane); return end
			if result.status ~= 0 then
				rejectForm(nextCx, pane, "No local branch named " .. base .. " in " .. project.name .. ".")
				return
			end
			local bases = records("repo-base")
			bases[project.id] = base
			tern.kv.set("repo-base", bases)
			finishForm(nextCx, pane)
			nextCx:toast("info", "Base branch changed", notificationLabel(project.name .. " → " .. base))
			redraw(nextCx)
		end)
end

-- The worktree's path is only known once Worktrunk has created it, so the
-- display name chosen at creation is attached afterwards, by branch.
local function applyCreatedName(job)
	local project = repoById(job.project)
	if not job.displayName or not project then return end
	wt.list(project, function(trees, _err, cx)
		if not trees or not cx then return end
		for _, tree in trees do
			if tree.branch == job.branch and not tree.is_main then
				local names = records("worktree-names")
				names[project.id] = names[project.id] or {}
				-- A rename made while setup ran wins over the name typed at creation.
				if names[project.id][tree.path] == nil then
					names[project.id][tree.path] = job.displayName
					tern.kv.set("worktree-names", names)
					redraw(cx)
				end
				return
			end
		end
	end)
end

local function forms(cx)
	for _, pane in cx.session:panes() do
		if pane.block == "overseer.form" and not inflight[pane.pane] then
			local request = tern.kv.get("pending-form:" .. tostring(pane.pane))
			if request then
				local response = request.response or tern.kv.get("form:" .. request.token)
				if response then
					-- Keep validation inputs until completion so a plugin reload can
					-- resume an in-flight request without leaving a submitted form stuck.
					request.response = response
					tern.kv.set("pending-form:" .. tostring(pane.pane), request)
					tern.kv.set("form:" .. request.token, nil)
					inflight[pane.pane] = true
					if response.cancelled then
						finishForm(cx, pane.pane)
					elseif request.mode == "create" and response.mode == "create" then
						createWorktree(cx, pane.pane, request, response)
					elseif request.mode == "rename" and response.mode == "rename" then
						renameWorktree(cx, pane.pane, request, response)
					elseif request.mode == "base" and response.mode == "base" then
						changeBase(cx, pane.pane, request, response)
					elseif request.mode == "space" and response.mode == "space" then
						renameSpace(cx, pane.pane, request, response)
					else
						rejectForm(cx, pane.pane, "Invalid form response. Please try again.")
					end
				end
			end
		end
	end
end

-- Forms post their responses through kv, which has no change notification.
-- While one is open, check every 100 ms so Back and Submit feel immediate;
-- the 750 ms tick covers everything else.
local watching = false
watchForms = function()
	if watching then return end
	watching = true
	local function step(cx)
		if not cx then watching = false; return end
		local open = false
		for _, pane in cx.session:panes() do
			if pane.block == "overseer.form" then open = true; break end
		end
		if not open then watching = false; return end
		local ok, err = pcall(forms, cx)
		if not ok then tern.log.warn("Overseer form check failed: " .. tostring(err)) end
		tern.timer(100, step)
	end
	tern.timer(100, step)
end

-- The helper's receipt is the only authority on an operation's outcome. A
-- terminal that looks closed or missing is just a hint: Tern can misreport a
-- pane while its program keeps running in the session daemon. Report failure
-- only once the helper process is confirmed gone without writing a receipt.
local function helperFailed(id, job)
	if dead[id] then return true end
	if probing[id] then return false end
	local pidFile = job.receipt .. ".pid"
	if not tern.fs.exists(pidFile) then
		-- Allow the login shell time to start the helper before it writes its PID.
		return os.time() - (job.started or 0) >= 30
	end
	local pid = tonumber(tern.fs.read(pidFile))
	if not pid then return true end
	probing[id] = true
	tern.process.run({ "/bin/kill", "-0", tostring(pid) }, { timeout_ms = 5000 }, function(result)
		probing[id] = nil
		if result and result.status ~= 0 then dead[id] = true end
	end)
	return false
end

-- What a finished job leaves to do: close its tab, update names and sessions,
-- log it, and tell you. Runs once the job is off the books, so a callback Tern
-- cuts short never repeats or misreports a job.
local function jobFinished(cx, job, status)
	local seconds = math.max(0, os.time() - (job.started or os.time()))
	-- Before the tab closes: a setup that printed warnings goes in the
	-- operation log, with its first warning, and nowhere else.
	local warnings = {}
	if cx.session:pane(job.pane) then
		warnings = oplog.warnings(oplog.readPane(cx, job.pane, oplog.READ_LINES, true) or {})
	end
	-- On success the output tab has served its purpose: close it (its helper is
	-- only waiting for Enter). Failures keep it open with the error on screen,
	-- including a deletion that reported success but left its directory.
	local succeeded = status == 0 and (job.kind ~= "remove" or not tern.fs.exists(job.path))
	if succeeded and cx.session:pane(job.pane) then cx.layout:close(job.pane) end
	local project = repoById(job.project)
	oplog.write(if succeeded and #warnings == 0 then "info" else "warn", {
		op = if job.kind == "remove" then "remove" else "create", event = if succeeded then "finished" else "failed",
		project = project and project.name, branch = job.branch, path = job.path, status = status, seconds = seconds,
		warnings = if #warnings > 0 then #warnings else nil, detail = warnings[1],
	})
	if job.kind == "remove" then
		if succeeded then
			local names = records("worktree-names")
			if names[job.project] then
				names[job.project][job.path] = nil
				tern.kv.set("worktree-names", names)
			end
			local closed, closeError = true, nil
			if job.session then closed, closeError = closeManagedSession(cx, job.path, job.session) end
			if closed then
				cx:toast("info", "Worktree deleted", notificationLabel(job.label))
			else
				tern.log.warn("Worktree deleted, but its session was left open: " .. tostring(closeError))
				cx:toast("error", "Worktree deleted", "Session still open. Check Tern’s log.")
			end
		else
			cx:toast("error", "Worktree deletion failed", "Check the Delete tab. Session kept.")
		end
	else
		-- Applied on failure too: a partially created worktree keeps its label.
		applyCreatedName(job)
		if status == 0 then
			cx:toast("info", "Worktree created", notificationLabel(job.displayName or job.branch))
		else
			cx:toast("error", "Worktree creation failed", "Check the Create tab for details.")
		end
	end
end

-- `inline` finishes jobs in this callback instead of one of their own: the
-- process clock does that when timers may not be running.
local function checkJobs(cx, inline)
	local jobs = records("jobs")
	local finished = {}
	for id, job in jobs do
		local status
		if tern.fs.exists(job.receipt) then
			status = tonumber(tern.fs.read(job.receipt)) or -1
		else
			local pane = cx.session:pane(job.pane)
			if (not pane or pane.exited ~= nil or pane.error) and helperFailed(id, job) then status = -1 end
		end
		if status ~= nil then finished[id] = { job = job, status = status } end
	end
	if next(finished) == nil then return end
	-- Off the books before the receipts go: a callback cut short in between
	-- leaves a stray receipt, never a job without one (which reads as failed).
	for id in finished do jobs[id] = nil end
	tern.kv.set("jobs", jobs)
	for id, done in finished do
		probing[id], dead[id] = nil, nil
		for _, file in { done.job.receipt, done.job.receipt .. ".pid" } do
			if tern.fs.exists(file) then tern.fs.remove(file) end
		end
		local function finish(finishCx)
			local ok, err = pcall(jobFinished, finishCx, done.job, done.status)
			if not ok then tern.log.warn("Overseer: finishing a job failed: " .. tostring(err)) end
		end
		if inline then finish(cx) else tern.timer(0, function(nextCx) if nextCx then finish(nextCx) end end) end
	end
	refresh(cx)
end

-- Creations' progress, read from their setup tab each tick: the step they're
-- on, and how long their output has been still. A question on the last line
-- (Worktrunk's hook approval prompt) marks one "needs you?" at once; so does
-- CREATE_QUIET_S without output, long enough that a quiet install or code
-- generation step doesn't trip it. Either tells you once. After a reload it
-- just starts over.
local CREATE_QUIET_S = 60

local function trackCreations(cx)
	local jobs = records("jobs")
	local changed = false
	for id, job in jobs do
		if job.kind == "create" and job.pane then
			local state = creationProgress[id] or { changedAt = os.time() }
			creationProgress[id] = state
			local lines = oplog.readPane(cx, job.pane, 15, false)
			if lines then
				local signature = table.concat(lines, "\n")
				if signature ~= state.signature then state.signature, state.changedAt = signature, os.time() end
				local step, asking = oplog.progress(lines)
				local quiet = os.time() - state.changedAt
				local needsYou = asking or quiet >= CREATE_QUIET_S
				-- The row shows elapsed time in 5 s steps: redraw when that, the step
				-- or the flag changes, not on every tick.
				local bucket = (os.time() - (job.started or os.time())) // 5
				if step ~= state.step or needsYou ~= state.needsYou or bucket ~= state.bucket then changed = true end
				state.step, state.asking, state.needsYou, state.bucket = step, asking, needsYou, bucket
				state.quiet = if needsYou and not asking then quiet else nil
				if needsYou and not state.told then
					state.told = true
					local project = repoById(job.project)
					local why = if asking then "It's asking a question in its setup tab."
						else "No output for " .. quiet .. " s. It may be waiting for an answer."
					cx:toast("error", "Creating " .. (job.displayName or job.branch) .. " may need you", why .. " Click its row.")
					oplog.write("warn", { op = "create", event = "needs-you", project = project and project.name,
						branch = job.branch, detail = why })
				end
			end
		end
	end
	for id in creationProgress do
		if not jobs[id] then creationProgress[id], changed = nil, true end
	end
	if changed then redraw(cx) end
end

-- Opens the operation log in a new tab with less. The command goes through
-- your shell; single quotes keep the path one word in bash, zsh, fish and nu.
local function openLog(cx)
	local file = oplog.path()
	if not tern.fs.exists(file) then cx:toast("info", "Nothing logged yet", "Overseer hasn't run an operation yet."); return end
	if string.find(file, "'", 1, true) then report(cx, "Can't open " .. file .. " through a shell."); return end
	local pane = cx.layout:new_tab({ command = "less -R +G '" .. file .. "'" })
	local tab = pane and cx.session:tab_of(pane)
	if tab then cx.layout:name_tab(tab, "Overseer log") end
end

-- The repository of the space shown now, if it's in one.
local function currentRepo(cx)
	local space = spaceInfo(cx, cx.sessions:current().id)
	return space and repoById(space.repo)
end

tern.command({ id = "projects", title = "Show or hide Spaces", icon = "branch", keys = { "cmd+alt+shift+p" }, run = togglePanel })
tern.command({ id = "add", title = "New space", icon = "folder", run = function(cx) pickSpace(cx) end })
tern.command({ id = "create", title = "Create worktree", icon = "branch", run = function(cx)
	local project = currentRepo(cx) or activeWorktree(cx)
	if project then openForm(cx, "create", project) else navigator(cx); cx:toast("info", "Not in a Git repository", "Click + beside a space in one.") end
end })
tern.command({ id = "ops-log", title = "Show Overseer's operation log", icon = "list", run = openLog })
-- Until Mission control (plan 3) shows proposals: starts the oldest proposed goal.
tern.command({ id = "start-goal", title = "Start proposed goal", icon = "branch", run = function(cx)
	cx:toast("info", "Starting the oldest proposed goal", "It opens in a session of its own; you stay here.")
	mission.startOldestProposedGoal(missionHooks.repoPath, function(err, goal, doneCx)
		local message = if err then "Couldn't start a goal: " .. err elseif not goal then "No goals are proposed. Agents propose them with goal_propose." else nil
		if message then
			tern.log.warn("Overseer: " .. message)
			if doneCx then doneCx:toast(if err then "error" else "info", "Start proposed goal", message) end
		end
	end)
end })

-- Session ids in the order Spaces lists them: each space, then its worktrees'
-- open sessions unless the space is collapsed. `at` gives every session's
-- place; one hidden in a collapsed space stands at that space's place.
local function listedOrder(cx)
	local order, at = {}, {}
	for _, space in model(cx).spaces do
		table.insert(order, space.id)
		at[space.id] = #order
		for _, worktree in space.worktrees do
			if worktree.sessionId then
				if not space.collapsed then table.insert(order, worktree.sessionId) end
				at[worktree.sessionId] = #order
			end
		end
	end
	return order, at
end

-- Shows the next (`delta` 1) or previous (-1) space in Spaces' order, wrapping.
local function stepSpace(cx, delta)
	if not requireLocal(cx) then return end
	local order, at = listedOrder(cx)
	local current = cx.sessions:current().id
	local index = at[current]
	local target
	if not index then
		target = order[1]
	elseif order[index] ~= current and delta < 0 then
		-- Hidden in a collapsed space: back goes to that space first.
		target = order[index]
	else
		target = order[(index - 1 + delta) % #order + 1]
	end
	if target and target ~= current then
		cx.sessions:switch(target)
		follow(cx)
	end
end

-- Moves the shown space above (`delta` -1) or below (1) its neighbour in
-- Spaces. Tern's list also holds the worktree sessions Spaces nests under
-- their repository, so it takes one of Tern's session moves per session
-- between the two.
local function moveSpace(cx, delta)
	if not requireLocal(cx) then return end
	local current = cx.sessions:current().id
	local spaces = {}
	for index, space in model(cx).spaces do spaces[index] = space.id end
	local index = table.find(spaces, current)
	if not index then
		cx:toast("info", "Worktree sessions stay with their repository", "Move the repository's space instead.")
		return
	end
	local neighbour = spaces[index + delta]
	if not neighbour then return end
	local position = {}
	for at, info in cx.session:sessions() do position[info.id] = at end
	local command = if delta < 0 then "move_session_up" else "move_session_down"
	for _ = 1, math.abs(position[current] - position[neighbour]) do cx:command(command) end
	redraw(cx)
end

tern.command({ id = "next-space", title = "Next space", icon = "arrow-down", keys = { "ctrl+cmd+]" }, run = function(cx) stepSpace(cx, 1) end })
tern.command({ id = "previous-space", title = "Previous space", icon = "arrow-up", keys = { "ctrl+cmd+[" }, run = function(cx) stepSpace(cx, -1) end })
tern.command({ id = "move-space-down", title = "Move space down", icon = "arrow-down", keys = { "ctrl+shift+cmd+down" }, run = function(cx) moveSpace(cx, 1) end })
tern.command({ id = "move-space-up", title = "Move space up", icon = "arrow-up", keys = { "ctrl+shift+cmd+up" }, run = function(cx) moveSpace(cx, -1) end })

-- Shows a pane (an agent, a setup tab): its space, then the pane.
local function showPane(cx, pane)
	local tab = pane and cx.session:tab_of(pane)
	if not tab then report(cx, "That pane has closed."); return end
	for _, info in cx.session:tabs() do
		if info.id == tab and info.session ~= cx.sessions:current().id then cx.sessions:switch(info.session) end
	end
	cx.layout:focus(pane)
end

-- Shows Mission control, in its own session (MISSION_SESSION) so it's always
-- in the same place; opens the session and block when missing. Not locked:
-- Tern's lock also stops you closing the session's tabs and blocks.
-- `task` (T-12) selects that task.
local function openMissionControl(cx, task)
	if task then tern.kv.set("mission:select", task) end
	for _, pane in cx.session:panes() do
		if pane.block == "overseer.mission" then showPane(cx, pane.pane); return end
	end
	local session
	for _, info in cx.sessions:list() do if info.name == MISSION_SESSION then session = info end end
	if session then cx.sessions:switch(session.id)
	else session = cx.sessions:create({ name = MISSION_SESSION, cwd = tern.getenv("HOME") }) end
	-- The session's shell tab, replaced by the block.
	local shell = cx.session:focused()
	local ok, pane = pcall(function() return cx:new_block("overseer.mission", if task then { task } else {}, "tab") end)
	if not ok or not pane then report(cx, "Couldn't open Mission control: " .. tostring(pane)); return end
	if shell and shell ~= pane then
		local info = cx.session:pane(shell)
		if info and info.kind == "terminal" then cx.layout:close(shell) end
	end
end

-- ⌘⇧S: a terminal in the corner runs `git fetch` so the SSH security key asks to be unlocked.
-- Tried in the focused pane's folder, then the current space's repository, then every known one.
-- The key is bound in your settings (keybinds["cmd+shift+s"]): Tern's own preset already uses it,
-- and a plugin's `keys` can't take a preset's keys.
unlockKey = function(cx)
	local dirs = {}
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	if info and info.cwd and info.cwd ~= "" then table.insert(dirs, expandHome(info.cwd)) end
	local project, worktree = activeWorktree(cx)
	if worktree then table.insert(dirs, worktree.path) end
	if project then table.insert(dirs, project.path) end
	for _, repo in repos do table.insert(dirs, repo.path) end
	unlock.open(cx, dirs)
end
tern.command({ id = "unlock-key", title = "Unlock SSH key (git fetch)", icon = "key", run = function(cx) unlockKey(cx) end })

tern.command({ id = "mission", title = "Mission control", icon = "list", keys = { "cmd+alt+shift+m" },
	run = function(cx) openMissionControl(cx) end })

-- Closes goal `ref` (G-3): marks it done on the server and closes its session.
-- Its worktrees stay, for review; Delete worktree removes them.
local function closeGoal(cx, ref)
	local goal
	for _, g in mission.state.get().goals do if g.ref == ref then goal = g end end
	if not goal then report(cx, "That goal is no longer active."); return end
	mission.api("POST", "/api/goals/" .. goal.ref .. "/close", { status = "done" }, function(_, err, nextCx)
		if err then if nextCx then report(nextCx, "Couldn't close " .. goal.ref .. ": " .. err) end; return end
		if nextCx and goal.tern_session then pcall(function() nextCx.sessions:close(tonumber(goal.tern_session)) end) end
		oplog.write("info", { op = "mission", event = "goal closed", detail = goal.ref })
	end)
end

-- Requests from the Mission control block (host half), which can't open
-- sessions or focus panes itself: kv `mission:requests`, a list of
-- { kind = "start", goal = "G-3" }, { kind = "go", task = "T-12" }, { kind = "review", task = "T-12" }, { kind = "session", goal = "G-3" } or { kind = "close", goal = "G-3" }.
-- Publishes how each task's agent is doing (kv `mission:agents`, omp session
-- → "working" | "waiting" | "idle") for the Mission control block, which
-- can't see agents. Written only when it changes.
local publishedAgents = ""
local function publishAgents()
	local states = {}
	for session, pane in mission.sessionPanes or {} do
		local id = tonumber(pane)
		if id then states[session] = agentStates[id] or (if unseen[id] then "waiting" else "idle") end
	end
	local encoded = tern.json.encode(states)
	if encoded ~= publishedAgents then publishedAgents = encoded; tern.kv.set("mission:agents", states) end
end

local function missionRequests(cx)
	publishAgents()
	local requests = tern.kv.get("mission:requests")
	if type(requests) ~= "table" or #requests == 0 then return end
	tern.kv.set("mission:requests", {})
	local ms = mission.state.get()
	for _, r in requests do
		if r.kind == "start" then
			for _, g in ms.goals do
				if g.ref == r.goal and g.status == "proposed" then
					local dir
					for _, t in ms.tasks do if t.goal == g.id then dir = t.repoPath or missionHooks.repoPath(t.repo); break end end
					mission.startGoal(g, dir or tern.getenv("HOME") or "/", function(err)
						if err then tern.log.warn("Overseer: couldn't start " .. g.ref .. ": " .. err) end
					end)
				end
			end
		elseif r.kind == "close" then closeGoal(cx, r.goal)
		elseif r.kind == "url" and type(r.url) == "string" and string.match(r.url, "^https://") then
			tern.process.run({ "/usr/bin/open", r.url }, { timeout_ms = 10000 }, function() end)
		elseif r.kind == "session" then
			for _, g in ms.goals do
				if g.ref == r.goal and g.tern_session then cx.sessions:switch(tonumber(g.tern_session)) end
			end
		elseif r.kind == "review" then
			-- A tab in the task's worktree; the Branch widget there opens Tern's
			-- Review changes (plugins can't open it directly in Tern 0.9.21).
			for _, t in ms.tasks do
				if t.ref == r.task and t.worktree then
					cx.layout:new_tab({ cwd = t.worktree })
					cx:toast("info", "Review " .. t.ref, "Click the Branch widget to step through its changes.")
				end
			end
		elseif r.kind == "go" then
			for _, t in ms.tasks do
				local pane = t.ref == r.task and t.session and mission.sessionPanes[t.session]
				if pane then showPane(cx, tonumber(pane)) end
			end
		end
	end
end

local function spaceRepo(cx, node)
	local space = spaceInfo(cx, view.spaceId(node))
	local repo = space and repoById(space.repo)
	if not repo then report(cx, "This space isn't in a Git repository. Refresh Spaces.") end
	return repo
end

tern.on("canvas_action", function(ev, cx)
	if not requireLocal(cx) then return true end
	if ev.act == "add" then pickSpace(cx)
	elseif ev.act == "refresh" then
		refreshByHand(cx)
	elseif ev.act == "collapse" then collapsed[ev.value] = not collapsed[ev.value]; redraw(cx)
	elseif ev.act == "mission" or ev.act == "Open Mission control" then openMissionControl(cx, ev.value)
	elseif ev.act == "goal" then
		local id = tonumber(ev.value)
		if id then cx.sessions:switch(id); follow(cx) end
	elseif ev.act == "Close goal" then closeGoal(cx, view.goalRef(ev.node))
	elseif ev.act == "create" then
		local project = repoById(ev.value)
		if project then openForm(cx, "create", project) end
	elseif ev.act == "open" then openWorktree(cx, ev.value)
	elseif ev.act == "pr" then
		-- In your default browser, where you're signed in to GitHub. (cx:open
		-- follows Tern's link routing: a browser split beside the sidebar.)
		if type(ev.value) == "string" and string.match(ev.value, "^https://") then
			tern.process.run({ "/usr/bin/open", ev.value }, { timeout_ms = 10000 }, function() end)
		end
	elseif ev.act == "space" then
		local id = tonumber(ev.value)
		if id then cx.sessions:switch(id); follow(cx) end
	elseif ev.act == "agent" or ev.act == "pane" then showPane(cx, tonumber(ev.value))
	elseif ev.act == "Rename space" then
		local space = spaceInfo(cx, view.spaceId(ev.node))
		if space then openForm(cx, "space", nil, nil, space)
		else report(cx, "Space not found. Refresh Spaces.") end
	elseif ev.act == "Close space" then requestSpaceClose(cx, view.spaceId(ev.node))
	elseif ev.act == "New worktree" then
		local repo = spaceRepo(cx, ev.node)
		if repo then openForm(cx, "create", repo) end
	elseif ev.act == "Change base branch" then
		local repo = spaceRepo(cx, ev.node)
		if repo then openForm(cx, "base", repo) end
	elseif ev.act == "Visualize PR" then
		visualizePr(cx, view.worktreePath(ev.node))
	elseif ev.act == "Rename" then
		local project, worktree = findWorktree(view.worktreePath(ev.node))
		if project then openForm(cx, "rename", project, worktree)
		else report(cx, "Worktree not found. Refresh Spaces.") end
	elseif ev.act == "Close session" then
		requestWorktreeAction(cx, "close", view.worktreePath(ev.node))
	elseif ev.act == "Delete worktree" then
		requestWorktreeAction(cx, "delete", view.worktreePath(ev.node))
	elseif ev.act == "confirm" then confirmWorktreeAction(cx, ev.value)
	elseif ev.act == "cancel" then
		if confirmation and confirmation.id == ev.value then endConfirmation(cx) end
	else return false end
	return true
end)

tern.override("new_tab", function(cx)
	if not localHost(cx) then return false end
	local _, worktree = activeWorktree(cx)
	if not worktree then return false end
	cx.layout:new_tab({ cwd = worktree.path })
	return true
end)

tern.chrome.status(function()
	return { { text = "Spaces", icon = "branch", command = "plugin.overseer.projects" } }
end)

-- Runs fn in a timer callback of its own, reporting (not raising) errors.
-- Tern gives every callback its own 50 ms of Lua and pauses all of a plugin's
-- timers after an overrun, so no single callback should carry a tick's work.
local function separately(fn)
	tern.timer(0, function(cx)
		if not cx then return end
		local ok, err = pcall(fn, cx)
		if not ok then
			local text = tostring(err)
			if problem ~= text then report(cx, text) end
		end
	end)
end

-- Remembers the name of each session seen for the first time (see namedByYou).
local function recordSessions(cx)
	local autoNames, changed = records("auto-names"), false
	for _, info in cx.session:sessions() do
		local key = tostring(info.id)
		if autoNames[key] == nil then autoNames[key], changed = info.name, true end
	end
	if changed then tern.kv.set("auto-names", autoNames) end
end

-- A session left with no tabs is closed: its last tab closed, and the
-- sidebar, parked in its deck by follow, would otherwise keep it open, empty.
-- Locked sessions and the window's last session stay.
local function closeEmptySessions(cx)
	local infos = cx.session:sessions()
	local left = #infos
	local managed = sessionsById(cx)
	for _, info in infos do
		local session = managed[tostring(info.id)]
		if left > 1 and #info.tabs == 0 and session and not session.locked then
			cx.sessions:close(info.id)
			left -= 1
		end
	end
end

-- A worktree removed outside Overseer (`wt merge`, `wt remove`, an agent)
-- leaves its session behind, cut off from its repository in Spaces. Close it
-- once the folder is gone, unless an agent still runs in it or Overseer's own
-- deletion is handling it. A repository's primary checkout is never closed.
local orphanWarned = {}
local function closeOrphanedSessions(cx)
	local agentSessions
	for path, binding in records("sessions") do
		local project = repoById(binding.project)
		local ok, exists = pcall(tern.fs.exists, path)
		if ok and not exists and not (project and project.path == path) and not removing(path) then
			if not agentSessions then
				agentSessions = {}
				local tabsById = {}
				for _, tab in cx.session:tabs() do tabsById[tab.id] = tab end
				for _, agent in agentPanes(tabsById, cx.session:panes()) do agentSessions[agent.tab.session] = true end
			end
			if not agentSessions[binding.id] then
				local closed, err = closeManagedSession(cx, path, binding)
				if closed then
					oplog.write("info", { op = "close", event = "worktree gone", path = path })
				elseif not orphanWarned[path] then
					orphanWarned[path] = true
					tern.log.warn("Overseer: left the session of deleted worktree " .. path .. " open: " .. tostring(err))
				end
			end
		end
	end
end

-- Each piece of a tick runs in a callback of its own, so a slow step can't
-- push the whole tick past its budget. The next tick is queued first, so a
-- tick Tern cuts short can't end the chain.
--
-- Upstream Overseer saw the tick stop for long stretches without Tern pausing
-- or logging anything, leaving creations and deletions unfinished. Still seen
-- on Tern 0.9.18 (ops.log: restarts with no budget pause before them), so
-- keep this even though 0.9.16 stopped slow timers dropping others. Its
-- health is watched from outside the timer hook: a generation number lets a
-- restart retire a lost chain, and `ensureTicking` runs from every event and
-- from a clock driven by a process (the process hook has a budget of its
-- own), restarting the tick when it is overdue.
local TICK_MS = 750
local TICK_STALL_MS = 5000
local tickGeneration = 0
local lastTick = tern.now()
-- When Tern paused the timer hook, until when (tern.now() ms); 0 when running.
local timerPausedUntil = 0
local tick

local function scheduleTick(generation)
	tern.timer(TICK_MS, function(cx) tick(generation, cx) end)
end

tick = function(generation, cx)
	-- A chain a restart replaced ends here, so two never run side by side.
	if generation ~= tickGeneration then return end
	scheduleTick(generation)
	lastTick = tern.now()
	if not cx or not localHost(cx) then return end
	separately(forms)
	-- Resumes fast form checks after a plugin reload left a form open.
	watchForms()
	separately(checkJobs)
	separately(trackCreations)
	if tern.now() - lastRefresh >= 15000 and #cx.canvas:list() > 0 then
		lastRefresh = tern.now()
		separately(refresh)
	end
	separately(recordSessions)
	separately(syncAgents)
	separately(function(tickCx)
		local live = {}
		for _, pane in tickCx.session:panes() do
			if pane.exited == nil and (pane.kind == "terminal" or pane.kind == "agent") then table.insert(live, tostring(pane.pane)) end
		end
		mission.tick(tickCx, live, missionHooks)
	end)
	separately(missionRequests)
	separately(follow)
	separately(closeEmptySessions)
	separately(closeOrphanedSessions)
	redraw(cx)
end

-- Restarts the tick when it is overdue and Tern hasn't paused the timer hook
-- (a pause holds due timers on purpose). Returns whether it restarted.
local function ensureTicking(source)
	local now = tern.now()
	local gap = now - lastTick
	if gap < TICK_STALL_MS or now < timerPausedUntil then return false end
	tickGeneration += 1
	lastTick = now
	scheduleTick(tickGeneration)
	oplog.write("warn", { op = "tick", event = "restarted",
		detail = string.format("no tick for %.0f s; restarted from %s", gap / 1000, source) })
	return true
end

-- A second clock, outside the timer hook: a short process every 5 s. When the
-- tick turns out to be overdue it is restarted. While timers can't run (the
-- tick was overdue, or Tern paused the timer hook, which doubles to minutes on
-- repeat trips), this clock finishes jobs whose receipts are in and keeps the
-- panel in the shown tab, so neither waits for timers to come back.
local function processClock()
	local ok = pcall(tern.process.run, { "/bin/sleep", "5" }, { timeout_ms = 15000 }, function(_result, cx)
		processClock()
		if not cx or not localHost(cx) then return end
		local restarted = ensureTicking("the process clock")
		if restarted or tern.now() < timerPausedUntil then
			local done, err = pcall(checkJobs, cx, true)
			if not done then tern.log.warn("Overseer: job check failed: " .. tostring(err)) end
			local followed, followErr = pcall(follow, cx)
			if not followed then tern.log.warn("Spaces panel: " .. tostring(followErr)) end
		end
	end)
	-- Can't start a process (shouldn't happen): events still check the tick.
	if not ok then tern.log.warn("Overseer: the process clock could not start") end
end

-- Mission control's session was locked before 2026-11-15, which blocked closing
-- its tabs; unlock it at load (window_start doesn't run on a plugin reload).
tern.timer(0, function(cx)
	if not cx then return end
	for _, info in cx.sessions:list() do
		if info.name == MISSION_SESSION and info.locked then cx.sessions:unlock(info.id) end
	end
end)

tern.on("window_start", function(cx)
	recordSessions(cx)
	refresh(cx)
	follow(cx)
end)
-- A space is named after its first terminal's folder, so follow cd.
tern.on("cwd", function(_ev, cx) redraw(cx) end)
tern.on("session_ended", function(ev, cx)
	forgetSession(ev.session)
	redraw(cx)
end)
tern.on("agent_state", function(ev, cx)
	ensureTicking("agent_state")
	setAgentState(cx, ev.pane, ev.new)
	redraw(cx)
end)
-- Tern pauses a hook that ran over its budget, then resumes it; timer
-- callbacks due meanwhile wait (ensureTicking leaves them be). Tern toasts the
-- overrun itself; the operation log keeps it.
tern.on("budget", function(ev)
	if ev.hook == "timer" then
		timerPausedUntil = if ev.state == "paused" then tern.now() + (ev.paused_ms or 0) + 1000 else 0
	end
	if ev.state == "paused" then
		oplog.write("warn", { op = "budget", event = "paused", detail = string.format("%s paused for %d ms after running over %d ms",
			ev.hook, ev.paused_ms or 0, ev.ms or 0) })
	else
		tern.log.warn("Overseer: " .. ev.hook .. " resumed")
	end
end)
-- Every tab, pane and focus change moves the panel into the shown tab and
-- draws it. The move and the draw each run in a timer callback of their own:
-- inline, a layout rebuild plus a draw risks an event hook's budget. Events
-- arriving before the move runs share it, using the latest event's tab.
local followQueued, followTab = false, nil
local function followSoon(_cx, tab)
	followTab = tab
	if followQueued then return end
	followQueued = true
	tern.timer(0, function(cx)
		followQueued = false
		if not cx then return end
		local ok, err = pcall(follow, cx, followTab)
		if not ok then tern.log.warn("Spaces panel: " .. tostring(err)) end
		redraw(cx)
		separately(closeEmptySessions)
	end)
end
tern.on("focus", function(ev, cx)
	ensureTicking("focus")
	for pane in unseen do
		if cx.session:tab_of(pane) == ev.tab then unseen[pane] = nil end
	end
	followSoon(cx, ev.tab)
end)
for _, name in { "tab_created", "tab_closed", "pane_created" } do
	tern.on(name, function(_ev, cx) ensureTicking(name); followSoon(cx) end)
end
-- A form pane closed without Back or Submit (⌘W, its tab closed) would leave
-- its request, and any answer it had sent, in kv for good. A confirmation
-- closed by a click outside it is cancelled.
tern.on("pane_closed", function(ev, cx)
	local key = "pending-form:" .. tostring(ev.pane)
	local request = tern.kv.get(key)
	if request then
		inflight[ev.pane] = nil
		tern.kv.set(key, nil)
		if request.token then tern.kv.set("form:" .. request.token, nil) end
	end
	if confirmation and confirmation.pane == ev.pane then confirmation = nil end
	agentStates[ev.pane], unseen[ev.pane] = nil, nil
	ensureTicking("pane_closed")
	followSoon(cx)
end)
-- Since Tern 0.9.16 processes outlive a reload, so an open folder picker would
-- stay up with nowhere to send its answer. The reload is logged so tick
-- restarts after it can be told from real stalls.
tern.on("unload", function()
	if picking then
		pcall(tern.process.run, { "/usr/bin/pkill", "-f", "Choose a folder for the new space" }, function() end)
	end
	oplog.write("info", { op = "plugin", event = "unloaded" })
end)
-- Timers and processes are restarted on reload; window_start intentionally is not.
scheduleTick(tickGeneration)
processClock()
