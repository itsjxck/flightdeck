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
	elseif item.agent == "waiting" then
		role, title = "overseer.dotWaiting", "Agent waiting for you"
	elseif item.agent == "working" then
		role, title = "overseer.dotAgent", "Agent working"
	elseif item.session then
		role, title = "overseer.dotOpen", "Session open"
	end
	return ui.el("div", { key = "status", role = role, title = title })
end

local function worktreeNode(worktree)
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
	local pr = worktree.pr and PR_STATES[worktree.pr.state]
	if pr then
		local summary = "#" .. tostring(worktree.pr.number) .. " · " .. pr.label
		table.insert(head, ui.el("button", {
			key = "pr", role = pr.role, title = summary .. " — open on GitHub", href = worktree.pr.url,
			aria = "Pull request " .. summary, actions = { click = "open" },
		}))
	end
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
	if space.repo then
		table.insert(head, button("create", "+", "create=" .. space.repo, "New worktree from " .. (space.base or "the base branch"), "overseer.rowButton"))
	end
	if #space.worktrees > 0 then
		table.insert(head, button("collapse", if space.collapsed then "▸" else "▾", "collapse=" .. space.repo,
			(if space.collapsed then "Show " else "Hide ") .. tostring(#space.worktrees) .. " worktrees", "overseer.rowButton"))
	end
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
	return ui.node("row", {
		key = "a" .. tostring(agent.pane), role = "overseer.agentRow",
		mark = if agent.active then "pick" else nil,
		title = agent.title, aria = agent.name .. ", " .. state.label .. ", " .. agent.program,
		actions = { click = "agent=" .. tostring(agent.pane) },
	}, {
		ui.el("div", { key = "status", role = state.dot }),
		ui.node("col", { key = "text", role = "overseer.agentText", grow = 1 }, {
			text("name", agent.name, "overseer.spaceName"),
			text("state", state.label .. " · " .. agent.program, state.role),
		}),
	})
end

local function confirmationNode(request)
	local copy = {
		delete = { "Delete worktree?", "Delete worktree", "Removes this directory, including ignored files. Keeps Git branches. Its session closes after successful removal. Stop file-writing tasks first." },
		close = { "Close session?", "Close session", "Stops all running programs and closes this session's tabs. Keeps the worktree files and Git branches." },
		space = { "Close space?", "Close space", "Stops all running programs and closes this space's tabs. Files stay as they are." },
	}
	local words = copy[request.kind]
	local buttons = { button("cancel", "Cancel", "cancel=" .. request.id, "Keep it open") }
	if not request.checking then
		table.insert(buttons, button("confirm", words[2], "confirm=" .. request.id, "Confirm " .. request.label, "overseer.dangerButton"))
	end
	return ui.node("col", { key = "confirmation", role = "overseer.confirmation" }, {
		text("title", words[1], "overseer.formHeading"),
		text("name", request.label, "overseer.spaceName"),
		text("path", request.path or "", "overseer.hint"),
		text("detail", words[3], "overseer.hint"),
		text("status", if request.checking then "Checking worktree..." else "", "overseer.hint"),
		ui.node("row", { key = "buttons", role = "overseer.formButtons" }, buttons),
	})
end

function View.render(model)
	local spaces = {
		ui.node("row", { key = "header", role = "overseer.header" }, {
			text("title", "Spaces", "overseer.heading", { grow = 1 }),
			button("add", "+", "add", "New space in a folder", "overseer.iconButton"),
			-- The glyph is its own element so only the arrow turns, not the button's frame.
			ui.el("button", {
				key = "refresh", role = "overseer.iconButton", actions = { click = "refresh" },
				title = if model.refreshing then "Refreshing…" else "Refresh worktrees",
				aria = if model.refreshing then "Refreshing" else "Refresh worktrees",
			}, {
				text("glyph", "↻", if model.refreshing then "overseer.refreshGlyphSpin" else "overseer.refreshGlyph"),
			}),
		}),
	}
	if model.confirmation then table.insert(spaces, confirmationNode(model.confirmation)) end
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
