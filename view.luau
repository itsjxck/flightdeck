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
		key = key, text = label, role = role or "overseer.button",
		title = title, actions = { click = action },
	})
end

-- Every Spaces control: a 24px square button holding one 16px icon (icons.css).
-- The icon is its own element, so a spinning ↻ turns without its frame.
local function iconButton(key, icon, action, title)
	return ui.el("button", {
		key = key, role = "overseer.iconButton", title = title, aria = title, actions = { click = action },
	}, { ui.el("div", { key = "icon", role = "overseer." .. icon }) })
end

local PR_STATES = {
	draft = { role = "overseer.prDraft", label = "Draft" },
	open = { role = "overseer.prOpen", label = "Open" },
	merged = { role = "overseer.prMerged", label = "Merged" },
	closed = { role = "overseer.prClosed", label = "Closed" },
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
	local role, title = "overseer.dotIdle", "No session"
	if item.deleting then
		role, title = "overseer.dotBusy", "Deleting"
	elseif item.creating then
		role, title = "overseer.dotBusy", "Creating"
	elseif item.agent == "waiting" then
		role, title = "overseer.dotWaiting", "Agent waiting for you"
	elseif item.agent == "working" then
		role, title = "overseer.dotAgent", "Agent working"
	elseif item.session then
		role, title = "overseer.dotOpen", "Session open"
	end
	return ui.el("div", { key = "status", role = role, title = title })
end

-- Opens the pull request on GitHub; its icon shows the PR's state. Sized like
-- the icon buttons. Nil for a state Overseer has no icon for.
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
	return ui.node("col", { key = "w" .. safeKey(worktree.path), role = "overseer.worktree" }, {
		ui.node("col", {
			key = "row", role = "overseer.creatingRow", title = creatingTitle(state),
			aria = state.label .. (if state.needsYou then ", creating, may need you" else ", creating"),
			actions = { click = if state.pane then "pane=" .. tostring(state.pane) else nil },
		}, {
			ui.node("row", { key = "head", role = "overseer.spaceHead" }, {
				statusDot(worktree),
				text("name", state.label, "overseer.worktreeName"),
				ui.el("div", { key = "spacer", grow = 1 }),
				if state.needsYou then text("badge", "needs you?", "overseer.badgeBad") else text("badge", "creating", "overseer.badgeWarn"),
			}),
			text("subtitle", creatingSubtitle(state), "overseer.spaceSubtitle"),
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
		text("name", worktree.label, "overseer.worktreeName"),
	}
	-- The conflicts badge already says the worktree has unfinished changes.
	if worktree.dirty and not worktree.conflicts then
		table.insert(head, text("dirty", "✱", "overseer.dirtyMark", { title = "Uncommitted changes" }))
	end
	table.insert(head, ui.el("div", { key = "spacer", grow = 1 }))
	if worktree.conflicts then table.insert(head, text("conflicts", "conflicts", "overseer.badgeBad")) end
	if worktree.deleting then table.insert(head, text("deleting", "deleting", "overseer.badgeWarn")) end
	local pr = prButton(worktree.pr)
	if pr then table.insert(head, pr) end
	return ui.node("col", {
		key = "w" .. safeKey(worktree.path), role = "overseer.worktree",
		mark = if worktree.active then "pick" else nil,
	}, {
		ui.node("row", {
			key = "row", role = "overseer.worktreeRow", title = details(worktree, branch),
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
	local nameRow = { statusDot(space), text("name", space.name, "overseer.spaceName") }
	if space.dirty then
		table.insert(nameRow, text("dirty", "✱", "overseer.dirtyMark", { title = "Uncommitted changes" }))
	end
	local head = {
		ui.node("col", {
			key = "row", role = "overseer.spaceRow", grow = 1,
			title = space.title,
			aria = space.name .. (if AGENT_TEXT[space.agent] then ", " .. AGENT_TEXT[space.agent] else ""),
			actions = { click = "space=" .. tostring(space.id), menu = menu },
		}, {
			ui.node("row", { key = "head", role = "overseer.spaceHead" }, nameRow),
			text("subtitle", space.subtitle or "", "overseer.spaceSubtitle"),
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
	if #buttons > 0 then table.insert(head, ui.node("row", { key = "buttons", role = "overseer.buttons" }, buttons)) end
	local children = { ui.node("row", { key = "line", role = "overseer.spaceLine" }, head) }
	if space.error then table.insert(children, text("error", space.error, "overseer.error")) end
	if not space.collapsed and #space.worktrees > 0 then
		local trees = {}
		for _, worktree in space.worktrees do table.insert(trees, worktreeNode(worktree)) end
		table.insert(children, ui.node("col", { key = "trees", role = "overseer.worktrees" }, trees))
	end
	return ui.node("col", {
		key = "s" .. tostring(space.id), role = "overseer.space",
		mark = if space.active then "pick" else nil,
	}, children)
end

local AGENT_STATES = {
	waiting = { dot = "overseer.dotWaiting", label = "waiting", role = "overseer.agentWaiting" },
	working = { dot = "overseer.dotAgent", label = "working", role = "overseer.agentWorking" },
	idle = { dot = "overseer.dotIdle", label = "idle", role = "overseer.agentIdle" },
}

local function agentNode(agent)
	local state = AGENT_STATES[agent.state] or AGENT_STATES.idle
	-- With a Huly issue (huly.luau), the state line names it after the state:
	-- "idle · OWLTR-1 · title", the issue a link that opens it in Huly.
	local stateLine = text("state", state.label, state.role)
	if agent.task then
		-- A plain text node, not a button: Tern's button styles add a box and a different font.
		stateLine = ui.node("row", { key = "state", role = "overseer.agentStateLine" }, {
			text("label", state.label .. " ·", state.role),
			text("task", agent.task.ident .. " · " .. agent.task.title, "overseer.taskLink", {
				title = "Open " .. agent.task.ident .. " in Huly", actions = { click = "huly=" .. agent.task.url },
			}),
		})
	end
	local lines = { text("name", agent.name, "overseer.spaceName"), stateLine }
	return ui.node("row", {
		key = "a" .. tostring(agent.pane), role = "overseer.agentRow",
		mark = if agent.active then "pick" else nil,
		title = agent.title,
		aria = agent.name .. ", " .. state.label .. (if agent.task then ", " .. agent.task.ident else ""),
		actions = { click = "agent=" .. tostring(agent.pane) },
	}, {
		ui.el("div", { key = "status", role = state.dot }),
		ui.node("col", { key = "text", role = "overseer.agentText", grow = 1 }, lines),
	})
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
	return ui.node("col", { key = "changes", role = "overseer.changes" }, {
		ui.node("text", { key = "summary", spans = { ui.span(summary, "strong") } }),
		ui.node("scroll", { key = "list", max = { h = "12lines" } }, rows),
	})
end

function View.confirmation(request)
	local words = View.confirmationWords(request)
	local buttons = { button("cancel", "Cancel", "cancel=" .. request.id, "Keep it open") }
	if not request.checking then
		table.insert(buttons, button("confirm", words.confirm, "confirm=" .. request.id, "Confirm " .. request.label, "overseer.dangerButton"))
	end
	local body = {
		text("name", request.label, "overseer.spaceName"),
		text("path", request.path or "", "overseer.hint"),
	}
	if request.changes then table.insert(body, changeList(request.changes)) end
	table.insert(body, text("detail", words.detail, "overseer.hint"))
	table.insert(body, text("status", if request.checking then "Checking worktree…" else "", "overseer.hint"))
	table.insert(body, ui.node("row", { key = "buttons", role = "overseer.formButtons" }, buttons))
	return ui.node("col", { key = "confirmation", role = "overseer.confirmation" }, body)
end

function View.render(model)
	local spaces = {
		ui.node("row", { key = "header", role = "overseer.header" }, {
			text("title", "Spaces", "overseer.heading", { grow = 1 }),
			ui.node("row", { key = "buttons", role = "overseer.buttons" }, {
				iconButton("add", "iconPlus", "add", "New space in a folder"),
				iconButton("refresh", if model.refreshing then "iconSyncSpin" else "iconSync", "refresh",
					if model.refreshing then "Refreshing…" else "Refresh worktrees"),
			}),
		}),
	}
	for _, space in model.spaces do table.insert(spaces, spaceNode(space)) end

	local agents = {
		ui.node("row", { key = "header", role = "overseer.header" }, {
			text("title", "Agents", "overseer.heading", { grow = 1 }),
			text("count", tostring(#model.agents), "overseer.count"),
		}),
	}
	for _, agent in model.agents do table.insert(agents, agentNode(agent)) end
	if #model.agents == 0 then
		table.insert(agents, text("empty", "No agents running", "overseer.hint"))
	end
	-- Agents go in the canvas's dock, so they stay at the bottom while spaces scroll.
	return ui.node("col", { key = "overseer", role = "overseer.navigator" }, spaces),
		ui.node("col", { key = "agents", role = "overseer.agents" }, agents)
end

return View
