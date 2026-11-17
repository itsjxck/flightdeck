local ui = tern.ui
local View = {}

local function safeKey(value)
	return (string.gsub(value, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end))
end

local function unhex(hex)
	if not hex or #hex % 2 ~= 0 then return nil end
	return (string.gsub(hex, "..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

-- Tern labels menu entries with the whole action string, including any =value.
-- Keep menu actions plain and recover their target from our keyed row node.
function View.worktreePath(node)
	return unhex(type(node) == "string" and node:match("%.w(%x+)%.row$") or nil)
end

function View.spaceId(node)
	return tonumber(type(node) == "string" and node:match("%.s(%d+)%.line%.row$") or nil)
end

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function button(key, label, action, title, role)
	return ui.el("button", {
		key = key, text = label, role = role or "flightdeck.button",
		title = title, actions = { click = action },
	})
end

-- Every Spaces control: a 24px square button holding one 16px icon (icons.css).
-- The icon is its own element, so a spinning ↻ turns without its frame.
local function iconButton(key, icon, action, title)
	return ui.el("button", {
		key = key, role = "flightdeck.iconButton", title = title, aria = title, actions = { click = action },
	}, { ui.el("div", { key = "icon", role = "flightdeck." .. icon }) })
end

local PR_STATES = {
	draft = { role = "flightdeck.prDraft", label = "Draft" },
	open = { role = "flightdeck.prOpen", label = "Open" },
	merged = { role = "flightdeck.prMerged", label = "Merged" },
	closed = { role = "flightdeck.prClosed", label = "Closed" },
}

local function divergence(value)
	if value.ahead == 0 and value.behind == 0 then return "up to date" end
	local parts = {}
	if value.ahead > 0 then table.insert(parts, tostring(value.ahead) .. " ahead") end
	if value.behind > 0 then table.insert(parts, tostring(value.behind) .. " behind") end
	return table.concat(parts, ", ")
end

local AGENT_TEXT = { waiting = "agent waiting for you", working = "agent working" }

-- A row's hover text: everything the compact row leaves out. Lines without
-- anything to say are omitted.
local function details(worktree, branch)
	local lines = { branch, worktree.path, "" }
	if worktree.conflicts then table.insert(lines, "Merge conflicts: resolve them before continuing") end
	local changes = worktree.changes
	if worktree.dirty and changes then
		local kinds = {}
		for _, kind in { { "staged", "staged" }, { "modified", "edited" }, { "renamed", "renamed" },
			{ "deleted", "deleted" }, { "untracked", "new files" } } do
			if changes[kind[1]] then table.insert(kinds, kind[2]) end
		end
		local parts = {}
		if changes.added_lines and changes.deleted_lines and changes.added_lines + changes.deleted_lines > 0 then
			table.insert(parts, "+" .. tostring(changes.added_lines) .. " −" .. tostring(changes.deleted_lines))
		end
		if #kinds > 0 then table.insert(parts, table.concat(kinds, ", ")) end
		if #parts > 0 then table.insert(lines, "Uncommitted: " .. table.concat(parts, " · ")) end
	elseif worktree.status_unknown then
		table.insert(lines, "Changes: not known yet (refreshing)")
	elseif not worktree.dirty then
		table.insert(lines, "No uncommitted changes")
	end
	if worktree.base then table.insert(lines, "Default branch: " .. divergence(worktree.base)) end
	if worktree.remote then
		table.insert(lines, (worktree.remote.name or "Upstream") .. ": " .. divergence(worktree.remote))
	end
	local pr = worktree.pr and PR_STATES[worktree.pr.state]
	if pr then table.insert(lines, "PR #" .. tostring(worktree.pr.number) .. " · " .. pr.label) end
	if worktree.session then
		table.insert(lines, "Session open" .. (if AGENT_TEXT[worktree.agent] then " · " .. AGENT_TEXT[worktree.agent] else ""))
	else
		table.insert(lines, "No session · click to open")
	end
	return table.concat(lines, "\n")
end

-- Status dot: hollow without a session, grey when open and quiet, pulsing
-- green while an agent works, haloed blue while one waits for you.
local function statusDot(item)
	local role, title = "flightdeck.dotIdle", "No session"
	if item.deleting then
		role, title = "flightdeck.dotBusy", "Deleting"
	elseif item.creating then
		role, title = "flightdeck.dotBusy", "Creating"
	elseif item.agent == "waiting" then
		role, title = "flightdeck.dotWaiting", "Agent waiting for you"
	elseif item.agent == "working" then
		role, title = "flightdeck.dotAgent", "Agent working"
	elseif item.session then
		role, title = "flightdeck.dotOpen", "Session open"
	end
	return ui.el("div", { key = "status", role = role, title = title })
end

-- Opens the pull request on GitHub; its icon shows the PR's state. Sized like
-- the icon buttons. Nil for a state Flightdeck has no icon for.
local function prButton(pr)
	local state = pr and PR_STATES[pr.state]
	if not state then return nil end
	local summary = "PR #" .. tostring(pr.number) .. " · " .. state.label
	return ui.el("button", {
		key = "pr", role = state.role, title = "Open " .. summary .. " on GitHub",
		aria = "Open pull request " .. summary, actions = { click = "pr=" .. pr.url },
	})
end

local function elapsed(seconds)
	if seconds < 60 then return tostring(seconds) .. "s" end
	return string.format("%dm %02ds", seconds // 60, seconds % 60)
end

-- A creation's second line: how long it has run, then what it's doing or why
-- it may need you.
local function creatingSubtitle(state)
	local parts = { "creating", elapsed(state.elapsed) }
	if state.asking then
		table.insert(parts, "asking a question in its setup tab")
	elseif state.quiet then
		table.insert(parts, "no output for " .. elapsed(state.quiet))
	elseif state.step then
		table.insert(parts, state.step)
	end
	return table.concat(parts, " · ")
end

local function creatingTitle(state)
	local lines = { "Creating " .. state.label, "Running for " .. elapsed(state.elapsed) }
	if state.step then table.insert(lines, "Last: " .. state.step) end
	if state.asking then
		table.insert(lines, "")
		table.insert(lines, "It's asking a question in its setup tab, such as a hook approval.")
	elseif state.needsYou then
		table.insert(lines, "")
		table.insert(lines, "No output for a while: it may be waiting for an answer, such as a hook approval.")
	end
	table.insert(lines, "")
	table.insert(lines, "Click to open its setup tab.")
	return table.concat(lines, "\n")
end

-- A worktree being created: its row opens the setup tab, and says how far
-- along it is or that it may need you (a hook approval, say).
local function creatingNode(worktree)
	local state = worktree.creating
	return ui.node("col", { key = "w" .. safeKey(worktree.path), role = "flightdeck.worktree" }, {
		ui.node("col", {
			key = "row", role = "flightdeck.creatingRow", title = creatingTitle(state),
			aria = state.label .. (if state.needsYou then ", creating, may need you" else ", creating"),
			actions = { click = if state.pane then "pane=" .. tostring(state.pane) else nil },
		}, {
			ui.node("row", { key = "head", role = "flightdeck.spaceHead" }, {
				statusDot(worktree),
				text("name", state.label, "flightdeck.worktreeName"),
				ui.el("div", { key = "spacer", grow = 1 }),
				if state.needsYou then text("badge", "needs you?", "flightdeck.badgeBad") else text("badge", "creating", "flightdeck.badgeWarn"),
			}),
			text("subtitle", creatingSubtitle(state), "flightdeck.spaceSubtitle"),
		}),
	})
end

local function worktreeNode(worktree)
	if worktree.creating then return creatingNode(worktree) end
	local branch = worktree.branch or "Detached HEAD"
	local menu = {}
	if not worktree.deleting then
		-- Menu entries show their action string verbatim, so actions are titled.
		if worktree.pr then table.insert(menu, "Visualize PR") end
		table.insert(menu, "Rename")
		if worktree.session then table.insert(menu, "Close session") end
		if not worktree.is_main then table.insert(menu, "Delete worktree") end
	end
	local head = {
		statusDot(worktree),
		text("name", worktree.label, "flightdeck.worktreeName"),
	}
	-- The conflicts badge already says the worktree has unfinished changes.
	if worktree.dirty and not worktree.conflicts then
		table.insert(head, text("dirty", "✱", "flightdeck.dirtyMark", { title = "Uncommitted changes" }))
	end
	table.insert(head, ui.el("div", { key = "spacer", grow = 1 }))
	if worktree.conflicts then table.insert(head, text("conflicts", "conflicts", "flightdeck.badgeBad")) end
	if worktree.deleting then table.insert(head, text("deleting", "deleting", "flightdeck.badgeWarn")) end
	local pr = prButton(worktree.pr)
	if pr then table.insert(head, pr) end
	return ui.node("col", {
		key = "w" .. safeKey(worktree.path), role = "flightdeck.worktree",
		mark = if worktree.active then "pick" else nil,
	}, {
		ui.node("row", {
			key = "row", role = "flightdeck.worktreeRow", title = details(worktree, branch),
			aria = worktree.label .. ", " .. (AGENT_TEXT[worktree.agent] or (if worktree.session then "session open" else "open session"))
				.. (if worktree.conflicts then ", merge conflicts" elseif worktree.dirty then ", uncommitted changes" else ""),
			actions = { click = if worktree.deleting then nil else "open=" .. worktree.path, menu = menu },
		}, head),
	})
end

local function spaceNode(space)
	local menu = { "Rename space" }
	if space.repo then
		table.insert(menu, "New worktree")
		table.insert(menu, "Change base branch")
	end
	table.insert(menu, "Close space")
	local nameRow = { statusDot(space), text("name", space.name, "flightdeck.spaceName") }
	if space.dirty then
		table.insert(nameRow, text("dirty", "✱", "flightdeck.dirtyMark", { title = "Uncommitted changes" }))
	end
	local head = {
		ui.node("col", {
			key = "row", role = "flightdeck.spaceRow", grow = 1,
			title = space.title,
			aria = space.name .. (if AGENT_TEXT[space.agent] then ", " .. AGENT_TEXT[space.agent] else ""),
			actions = { click = "space=" .. tostring(space.id), menu = menu },
		}, {
			ui.node("row", { key = "head", role = "flightdeck.spaceHead" }, nameRow),
			text("subtitle", space.subtitle or "", "flightdeck.spaceSubtitle"),
		}),
	}
	local buttons = {}
	local pr = prButton(space.pr)
	if pr then table.insert(buttons, pr) end
	if space.repo then
		table.insert(buttons, iconButton("create", "iconPlus", "create=" .. space.repo, "New worktree from " .. (space.base or "the base branch")))
	end
	if #space.worktrees > 0 then
		table.insert(buttons, iconButton("collapse", if space.collapsed then "iconCollapsed" else "iconExpanded", "collapse=" .. space.repo,
			(if space.collapsed then "Show " else "Hide ") .. tostring(#space.worktrees) .. " worktrees"))
	end
	if #buttons > 0 then table.insert(head, ui.node("row", { key = "buttons", role = "flightdeck.buttons" }, buttons)) end
	local children = { ui.node("row", { key = "line", role = "flightdeck.spaceLine" }, head) }
	if space.error then table.insert(children, text("error", space.error, "flightdeck.error")) end
	if not space.collapsed and #space.worktrees > 0 then
		local trees = {}
		for _, worktree in space.worktrees do table.insert(trees, worktreeNode(worktree)) end
		table.insert(children, ui.node("col", { key = "trees", role = "flightdeck.worktrees" }, trees))
	end
	return ui.node("col", {
		key = "s" .. tostring(space.id), role = "flightdeck.space",
		mark = if space.active then "pick" else nil,
	}, children)
end

local AGENT_STATES = {
	waiting = { dot = "flightdeck.dotWaiting", label = "waiting" },
	working = { dot = "flightdeck.dotAgent", label = "working" },
	idle = { dot = "flightdeck.dotIdle", label = "idle" },
}

-- One line per agent: its dot (the state), its name, then its Mission control
-- task (ref and title, cut to fit), which opens the task there.
local function agentNode(agent)
	local state = AGENT_STATES[agent.state] or AGENT_STATES.idle
	local children = {
		ui.el("div", { key = "status", role = state.dot }),
		text("name", agent.name, "flightdeck.spaceName", { grow = if agent.task then nil else 1 }),
	}
	if agent.task then
		table.insert(children, text("task", "· " .. agent.task.ref .. " · " .. agent.task.title, "flightdeck.taskLink", {
			title = agent.task.ref .. " · " .. agent.task.title .. "\nOpen it in Mission control",
			actions = { click = "mission=" .. agent.task.ref },
		}))
	end
	return ui.node("row", {
		key = "a" .. tostring(agent.pane), role = "flightdeck.agentRow",
		mark = if agent.active then "pick" else nil,
		title = agent.title .. "\n" .. state.label,
		aria = agent.name .. ", " .. state.label .. (if agent.task then ", " .. agent.task.ref else ""),
		actions = { click = "agent=" .. tostring(agent.pane) },
	}, children)
end

-- "Needs you N": the sidebar's top line while questions wait; opens Mission control.
-- The Mission control button, always at the top: its count and dot show
-- questions waiting for you.
local function missionNode(count, active)
	local children = {
		if count > 0 then ui.el("div", { key = "status", role = "flightdeck.dotWaiting" })
			else ui.el("div", { key = "status", role = "flightdeck.missionIcon" }),
		text("name", "Mission control", "flightdeck.spaceName", { grow = 1 }),
	}
	if count > 0 then table.insert(children, text("count", tostring(count) .. (if count == 1 then " needs you" else " need you"), "flightdeck.badgeBad")) end
	return ui.node("row", {
		key = "mission", role = if active then "flightdeck.missionActive" else "flightdeck.mission",
		title = "Open Mission control (⌘⌥⇧M)",
		aria = "Mission control" .. (if count > 0 then ", " .. tostring(count) .. (if count == 1 then " question needs you" else " questions need you") else ""),
		actions = { click = "mission" },
	}, children)
end

local TASK_STATUS = { ready = "ready", todo = "waiting on others", done = "done", failed = "failed", dropped = "dropped" }

-- A goal: its row (session, progress, menu) and, unfolded, one row per task.
local function goalNode(goal)
	-- Finished (the coordinator reported): green until you close it, unless a question waits.
	local dot = if goal.dot == "waiting" then AGENT_STATES.waiting.dot
		elseif goal.finished then "flightdeck.dotDone"
		elseif goal.dot then AGENT_STATES[goal.dot].dot else "flightdeck.dotOpen"
	local head = {
		ui.el("div", { key = "status", role = dot }),
		text("name", goal.ref .. " · " .. goal.title, "flightdeck.spaceName", { grow = 1 }),
	}
	if goal.needsYou > 0 then table.insert(head, text("needs", tostring(goal.needsYou), "flightdeck.badgeBad", { title = "Questions waiting for you" })) end
	table.insert(head, if goal.finished
		then text("progress", "finished", "flightdeck.count", { title = "Finished: review its worktrees, then Close goal (right-click)" })
		else text("progress", tostring(goal.progress.done) .. "/" .. tostring(goal.progress.total), "flightdeck.count", { title = "Tasks done" }))
	local line = ui.node("row", { key = "line", role = "flightdeck.spaceLine" }, {
		ui.node("row", {
			key = "row", role = "flightdeck.spaceRow", grow = 1, title = "Go to " .. goal.ref .. "'s session",
			-- The coordinator's pane, else the goal's session, else Mission control.
			actions = { click = if goal.coordinatorPane then "pane=" .. goal.coordinatorPane
				elseif goal.session then "goal=" .. goal.session else "mission", menu = { "Open Mission control", "Close goal" } },
		}, { ui.node("row", { key = "head", role = "flightdeck.spaceHead", grow = 1 }, head) }),
		ui.node("row", { key = "buttons", role = "flightdeck.buttons" }, {
			iconButton("collapse", if goal.collapsed then "iconCollapsed" else "iconExpanded", "collapse=goal:" .. goal.ref,
				(if goal.collapsed then "Show " else "Hide ") .. tostring(#goal.tasks) .. " tasks"),
		}),
	})
	local children = { line }
	if not goal.collapsed then
		local rows = {}
		for _, t in goal.tasks do
			local state = t.state and AGENT_STATES[t.state]
			table.insert(rows, ui.node("row", {
				key = "t" .. t.ref, role = "flightdeck.worktreeRow",
				title = t.ref .. " · " .. t.title .. "\n" .. (if state then "Agent " .. state.label else TASK_STATUS[t.status] or t.status),
				actions = { click = if t.pane then "pane=" .. t.pane else "mission=" .. t.ref },
			}, {
				ui.el("div", { key = "status", role = if state then state.dot else "flightdeck.dotIdle" }),
				text("name", t.ref .. " · " .. t.title, "flightdeck.worktreeName", { grow = 1 }),
				text("label", if state then state.label elseif t.waitsOn then "waits on " .. t.waitsOn else TASK_STATUS[t.status] or t.status, "flightdeck.taskState"),
			}))
		end
		table.insert(children, ui.node("col", { key = "tasks", role = "flightdeck.worktrees" }, rows))
	end
	return ui.node("col", { key = "g" .. goal.ref, role = "flightdeck.space" }, children)
end

-- The goal whose sidebar row `node` (an action's node id) belongs to, e.g. "G-3".
function View.goalRef(node)
	return type(node) == "string" and node:match("%.g(G%-?%d+)%.line") or nil
end

-- A confirmation, shown in a canvas of its own over the tab; the canvas's
-- title asks the question.
View.CONFIRMATIONS = {
	delete = { title = "Delete worktree?", confirm = "Delete worktree", detail = "Removes this directory, including ignored files. Keeps Git branches. Its session closes after successful removal. Stop file-writing tasks first." },
	forceDelete = { title = "Delete worktree with uncommitted changes?", confirm = "Force delete", detail = "Force deleting removes these changes and the directory's ignored files for good. Keeps Git branches and commits. Its session closes after successful removal. Stop file-writing tasks first." },
	close = { title = "Close session?", confirm = "Close session", detail = "Stops all running programs and closes this session's tabs. Keeps the worktree files and Git branches." },
	space = { title = "Close space?", confirm = "Close space", detail = "Stops all running programs and closes this space's tabs. Files stay as they are." },
}

-- A deletion that found uncommitted changes asks again, as Force delete.
function View.confirmationWords(request)
	return View.CONFIRMATIONS[if request.kind == "delete" and request.force then "forceDelete" else request.kind]
end

-- What a forced deletion loses, like `git status --short` with line counts:
-- the status code in amber, the path, the counts green and red. It scrolls
-- past a dozen lines.
local function changeList(changes)
	local rows = {}
	for index, file in ipairs(changes.files) do
		local spans = { ui.span(file.code, "warning"), " ", ui.span(file.path, "path") }
		if file.added and file.added > 0 then table.insert(spans, ui.span("  +" .. tostring(file.added), "success")) end
		if file.deleted and file.deleted > 0 then table.insert(spans, ui.span("  −" .. tostring(file.deleted), "error")) end
		table.insert(rows, ui.node("text", { key = "c" .. tostring(index), spans = spans, wrap = "none", truncate = "middle" }))
	end
	local hidden = changes.total - #changes.files
	if hidden > 0 then
		table.insert(rows, ui.node("text", { key = "more", spans = { ui.span("… and " .. tostring(hidden) .. " more", "muted") } }))
	end
	local summary = tostring(changes.total) .. " uncommitted change" .. (if changes.total == 1 then "" else "s")
	return ui.node("col", { key = "changes", role = "flightdeck.changes" }, {
		ui.node("text", { key = "summary", spans = { ui.span(summary, "strong") } }),
		ui.node("scroll", { key = "list", max = { h = "12lines" } }, rows),
	})
end

function View.confirmation(request)
	local words = View.confirmationWords(request)
	local buttons = { button("cancel", "Cancel", "cancel=" .. request.id, "Keep it open") }
	if not request.checking then
		table.insert(buttons, button("confirm", words.confirm, "confirm=" .. request.id, "Confirm " .. request.label, "flightdeck.dangerButton"))
	end
	local body = {
		text("name", request.label, "flightdeck.spaceName"),
		text("path", request.path or "", "flightdeck.hint"),
	}
	if request.changes then table.insert(body, changeList(request.changes)) end
	table.insert(body, text("detail", words.detail, "flightdeck.hint"))
	table.insert(body, text("status", if request.checking then "Checking worktree…" else "", "flightdeck.hint"))
	table.insert(body, ui.node("row", { key = "buttons", role = "flightdeck.formButtons" }, buttons))
	return ui.node("col", { key = "confirmation", role = "flightdeck.confirmation" }, body)
end

function View.render(model)
	local spaces = {}
	table.insert(spaces, missionNode(model.needsYou or 0, model.missionActive == true))
	table.insert(spaces, ui.node("row", { key = "header", role = "flightdeck.header" }, {
		text("title", "Spaces", "flightdeck.heading", { grow = 1 }),
		ui.node("row", { key = "buttons", role = "flightdeck.buttons" }, {
			iconButton("add", "iconPlus", "add", "New space in a folder"),
			iconButton("refresh", if model.refreshing then "iconSyncSpin" else "iconSync", "refresh",
				if model.refreshing then "Refreshing…" else "Refresh worktrees"),
		}),
	}))
	for _, space in model.spaces do table.insert(spaces, spaceNode(space)) end
	if model.goals and #model.goals > 0 then
		table.insert(spaces, ui.el("div", { key = "goals-rule", role = "flightdeck.rule" }))
		table.insert(spaces, ui.node("row", { key = "goals-header", role = "flightdeck.header" }, {
			text("title", "Goals", "flightdeck.heading", { grow = 1 }),
			text("count", tostring(#model.goals), "flightdeck.count"),
		}))
		for _, goal in model.goals do table.insert(spaces, goalNode(goal)) end
	end

	local agents = {
		ui.node("row", { key = "header", role = "flightdeck.header" }, {
			text("title", "Agents", "flightdeck.heading", { grow = 1 }),
			text("count", tostring(#model.agents), "flightdeck.count"),
		}),
	}
	for _, agent in model.agents do table.insert(agents, agentNode(agent)) end
	if #model.agents == 0 then
		table.insert(agents, text("empty", "No agents running", "flightdeck.hint"))
	end
	-- Agents go in the canvas's dock, so they stay at the bottom while spaces scroll.
	return ui.node("col", { key = "flightdeck", role = "flightdeck.navigator" }, spaces),
		ui.node("col", { key = "agents", role = "flightdeck.agents" }, agents)
end

return View
