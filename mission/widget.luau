-- The widget-bar widget `flightdeck/mission` (window half): what needs you at
-- a glance ("1 question · 2 goals"), and a hover card with a row per waiting
-- question (its first options as answer buttons, Go to agent) and per running
-- goal (Open session), then Mission control. window.luau registers it and
-- routes the card's buttons (`widget_action`).
local M = {}

M.ID = "mission"

-- Characters per card row, question rows, options listed.
local WIDTH, QUESTION_LINES, MAX_OPTIONS = 42, 5, 4

-- Keeps a line to n characters, ending in "…" when cut.
local function short(s, n)
	s = string.gsub(tostring(s), "%s+", " ")
	if utf8.len(s) <= n then return s end
	return string.sub(s, 1, utf8.offset(s, n) - 1) .. "…"
end

-- `text` in lines of at most `width` characters, broken between words, at most `max` lines (the last ends in "…" when cut). Pure.
function M.wrap(text, width, max)
	local lines, current = {}, ""
	for word in string.gmatch(string.gsub(tostring(text), "[*`]", ""), "%S+") do
		if current == "" then current = word
		elseif utf8.len(current) + 1 + utf8.len(word) <= width then current ..= " " .. word
		else table.insert(lines, current); current = word end
	end
	if current ~= "" then table.insert(lines, current) end
	if #lines > max then
		lines = { table.unpack(lines, 1, max) }
		lines[max] = short(lines[max], width - 1) .. "…"
	end
	for i, l in lines do lines[i] = short(l, width) end
	return lines
end

-- The widget's view from a /api/state (mission/state.luau). Pure.
function M.view(ms)
	local waiting = ms.waiting or {}
	local running = {}
	for _, g in (ms.goals or {}) do if g.status == "active" then table.insert(running, g) end end
	local parts = {}
	if #waiting > 0 then table.insert(parts, tostring(#waiting) .. (if #waiting == 1 then " question" else " questions")) end
	if #running > 0 then table.insert(parts, tostring(#running) .. (if #running == 1 then " goal" else " goals")) end

	local card = {}
	for _, q in waiting do
		-- Card rows don't wrap and the card is narrow: the question over a few rows of its own, each
		-- option on a row with one short button (long button labels push the card wider than the screen).
		local lines = M.wrap(q.question, WIDTH, QUESTION_LINES)
		for i, line in lines do
			table.insert(card, { text = line, tone = "warn" })
		end
		for i, option in (q.options or {}) do
			if i > MAX_OPTIONS then break end
			table.insert(card, { id = "q:" .. q.task .. ":" .. tostring(i), text = tostring(i) .. ". " .. short(option, WIDTH - 8),
				tone = if q.recommended == i then "accent" else nil, actions = { { id = "answer", label = "Pick" } } })
		end
		table.insert(card, { id = "q:" .. q.task, text = q.task .. (if q.options and #q.options > MAX_OPTIONS then " · more options in Mission control" else " · or answer in its pane"),
			tone = "muted", actions = { { id = "go", label = "Go to agent" } } })
	end
	for _, g in running do
		local p = g.progress or { done = 0, total = 0 }
		table.insert(card, { id = "g:" .. g.ref, label = g.ref, text = short(g.title, 120) .. " · " .. tostring(p.done) .. "/" .. tostring(p.total),
			actions = if g.tern_session then { { id = "session", label = "Open session" } } else nil })
	end
	table.insert(card, { id = "mission", text = if #card == 0 then "Nothing needs you." else "Everything else", tone = "muted",
		actions = { { id = "open", label = "Mission control" } } })

	return {
		text = if #parts > 0 then table.concat(parts, " · ") else "idle",
		tone = if #waiting > 0 then "warn" elseif #running > 0 then "accent" else "muted",
		card = card,
	}
end

do
	assert(table.concat(M.wrap("aa bb cc dd", 5, 9), "|") == "aa bb|cc dd" and #M.wrap(string.rep("word ", 50), 20, 3) == 3
		and string.sub(M.wrap(string.rep("word ", 50), 20, 3)[3], -3) == "…", "mission.widget.wrap self-check")
	local v = M.view({ waiting = { { task = "G2.1", question = "Merge?", options = { "Yes, merge it now please", "No" }, recommended = 1 } },
		goals = { { ref = "G2", title = "t", status = "active", tern_session = "9", progress = { done = 1, total = 3 } }, { ref = "G3", status = "proposed", title = "p" } } })
	-- question, 2 options, go row, goal, Mission control
	assert(v.text == "1 question · 1 goal" and v.tone == "warn" and #v.card == 6, "mission.widget.view self-check")
	assert(v.card[2].id == "q:G2.1:1" and v.card[2].tone == "accent" and v.card[4].actions[1].id == "go" and v.card[5].text == "t · 1/3",
		"mission.widget.view card self-check")
	assert(M.view({}).text == "idle" and M.view({}).card[1].text == "Nothing needs you.", "mission.widget.view idle self-check")
end

return M
