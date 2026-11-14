-- The Mission control block (host half): wires ui/model.luau (data) and
-- ui/render.luau (view) into a Tern plugin block with keys, a reply field
-- and a 2-second refresh. Actions the host can't take (open a goal's
-- session, focus a pane, open a review tab) go to the window as requests.
local Input = require("../input")
local model = require("./model")
local render = require("./render")

local POLL_MS = 2000

local EMPTY = { needs = {}, proposed = {}, working = {}, todo = {} }

-- The selectable rows and the index of the selected one (by ref, so a refresh keeps it).
local function rows(state)
	local list = model.selectable(state.sections, state.showTodo)
	local index = 1
	for i, r in list do
		local ref = r.item.task or r.item.ref
		if ref == state.selectedRef then index = i end
	end
	return list, index
end

local function selectedRow(state)
	local list, index = rows(state)
	return list[index]
end

-- Who the reply field writes to: the open thread, else the selected question.
local function replyTarget(state)
	if state.newTask then return "New task", "Title of a task for later, Enter adds it" end
	if state.thread then return state.thread.task, nil end
	local row = selectedRow(state)
	if row and row.kind == "question" then return row.item.task, nil end
	return nil, nil
end

local function refresh(state, cx)
	model.api("GET", "/api/state", nil, function(s, err)
		state.error = err
		if s then state.sections = model.sections(s) end
		local pending = tern.kv.get("mission:select")
		if type(pending) == "string" then state.selectedRef = pending; tern.kv.set("mission:select", nil) end
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
	if state.newTask then
		local row = selectedRow(state)
		local repo = row and row.item.repo or "personal"
		model.api("POST", "/api/tasks", { title = body, repo = repo }, function(_, err) state.error = err; refresh(state, cx) end)
		state.newTask = false
	elseif target then
		model.api("POST", "/api/answer", { task = target, body = body }, function(_, err) state.error = err; refresh(state, cx) end)
	end
	state.reply = Input.new("")
end

local function answerOption(state, cx, task, option)
	local q
	for _, item in state.sections.needs do if item.task == task then q = item end end
	local text = q and q.options and q.options[option]
	if not text then return false end
	model.api("POST", "/api/answer", { task = task, body = text }, function(_, err) state.error = err; refresh(state, cx) end)
	return true
end

-- Enter on a row with an empty reply: start a proposal, go to a task's agent.
local function activate(state, cx)
	local row = selectedRow(state)
	if not row then return end
	if row.kind == "proposal" then
		model.request({ kind = "start", goal = row.item.ref })
		state.error = "Starting " .. row.item.ref .. " in a session of its own…"
	elseif row.kind == "task" or row.kind == "todo" then
		model.request({ kind = "go", task = row.item.ref })
	end
end

local DEF = {
	init = function(cx, args)
		local state = {
			sections = EMPTY, selectedRef = args[1], showTodo = false, thread = nil,
			reply = Input.new(""), newTask = false, error = nil, alive = true,
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
		local to, hint = replyTarget(state)
		local agents = tern.kv.get("mission:agents")
		local main, dock = render.view({
			sections = state.sections, selectedRef = row and (row.item.task or row.item.ref), showTodo = state.showTodo,
			thread = state.thread, reply = state.reply, replyTo = to, replyHint = hint, error = state.error,
			agentOf = function(session) return if type(agents) == "table" and session then agents[session] else nil end,
		})
		return { main = main, dock = dock }
	end,
	key = function(state, key, cx)
		local list, index = rows(state)
		local typing = state.reply.text ~= ""
		if key.name == "up" or key.name == "down" then
			local next = list[math.clamp(index + (if key.name == "up" then -1 else 1), 1, math.max(#list, 1))]
			if next then state.selectedRef = next.item.task or next.item.ref end
		elseif key.name == "escape" or key.name == "esc" then
			if typing then state.reply = Input.new("")
			elseif state.newTask then state.newTask = false
			elseif state.thread then state.thread = nil
			else return false end
		elseif key.name == "enter" then
			if typing then send(state, cx) else activate(state, cx) end
		elseif not typing and not state.newTask and string.match(key.name, "^[1-9]$") then
			local row = list[index]
			if not (row and row.kind == "question" and answerOption(state, cx, row.item.task, tonumber(key.name))) then return false end
		elseif not typing and not state.newTask and key.name == "o" then
			local row = list[index]
			if not row or row.kind == "proposal" then return false end
			openThread(state, cx, row.item.task or row.item.ref)
		elseif not typing and not state.newTask and key.name == "r" then
			local row = list[index]
			if not row or row.kind ~= "task" then return false end
			model.request({ kind = "review", task = row.item.ref })
		elseif not typing and not state.newTask and key.name == "t" then
			state.showTodo = not state.showTodo
		elseif not typing and not state.newTask and key.name == "n" then
			state.newTask = true
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
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			state.selectedRef = ev.item
			if ev.ev == "activate" then activate(state, cx) end
			return
		end
		if ev.ev == "action" and ev.act == "start" and type(ev.item) == "string" then
			model.request({ kind = "start", goal = ev.item }); state.error = "Starting " .. ev.item .. " in a session of its own…"
			return
		end
		if ev.ev ~= "action" or type(ev.act) ~= "string" then return end
		-- Tern splits "verb=value" actions at the first "="; put them back together.
		local act = if ev.value ~= nil then ev.act .. "=" .. tostring(ev.value) else ev.act
		local verb, a, b = string.match(act, "^(%a+)=([^=]+)=?(.*)$")
		if verb == "answer" then answerOption(state, cx, a, tonumber(b))
		elseif verb == "select" then state.selectedRef = a
		elseif verb == "session" then model.request({ kind = "session", goal = a })
		elseif verb == "close" then model.request({ kind = "close", goal = a }); state.error = "Closing " .. a .. "…"
		elseif verb == "start" then model.request({ kind = "start", goal = a }); state.error = "Starting " .. a .. " in a session of its own…"
		end
	end,
	save = function(state)
		return { showTodo = state.showTodo }
	end,
}
tern.block.define("mission", DEF)
