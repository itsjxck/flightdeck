-- Mission control's popup forms (host half): New goal, New task, Link an
-- issue to a goal. A dialog is plain data, { kind, title, submit, note,
-- fields = { { id, label, placeholder, required, input } }, focus }; this
-- module builds them, handles their keys and draws them as a modal overlay in
-- the block's layer. ui/block.luau sends what they submit.
local Input = require("../input")
local ui = tern.ui

local M = {}

local function field(id, label, placeholder, required, text)
	return { id = id, label = label, placeholder = placeholder, required = required, input = Input.new(text or "") }
end

-- `opts`: goal { issues = refs }, task { repo }, link { issue }.
function M.new(kind, opts)
	opts = opts or {}
	if kind == "goal" then
		return { kind = kind, title = "New goal", submit = "Propose goal", focus = 1, issues = opts.issues,
			note = if opts.issues and #opts.issues > 0 then "Linked issues: " .. table.concat(opts.issues, ", ")
				else "Its coordinator reads the repositories and plans the tasks. Start it from Backlog when you're ready.",
			fields = {
				field("title", "What should be true when it's done?", "A short title", true, opts.title),
				field("body", "Details for the coordinator", "Repositories, constraints, links (optional)", false),
			} }
	elseif kind == "task" then
		return { kind = kind, title = "New task", submit = "Add task", focus = 1,
			note = "A task for later, outside goals.",
			fields = {
				field("title", "Task", "What needs doing", true),
				field("repo", "Repository", "Its name, as in Repos", true, opts.repo),
			} }
	elseif kind == "link" then
		return { kind = kind, title = "Link " .. opts.issue, submit = "Link", focus = 1, issue = opts.issue,
			note = "Its coordinator and workers see the issue; Overseer comments on it when the goal starts and finishes.",
			fields = { field("goal", "Goal", "G3", true) } }
	end
	error("unknown dialog " .. tostring(kind))
end

-- The fields' text by id, trimmed. Pure.
function M.values(d)
	local out = {}
	for _, f in d.fields do out[f.id] = (string.gsub(f.input.text, "^%s*(.-)%s*$", "%1")) end
	return out
end

-- The first required field left empty, or nil when the dialog can be submitted. Pure.
function M.missing(d)
	for i, f in d.fields do
		if f.required and not string.find(f.input.text, "%S") then return i end
	end
	return nil
end

-- A key in the dialog: returns "submit", "cancel", or nil (handled here: typing, Tab, Enter to the next field).
function M.key(d, key)
	if key.name == "escape" or key.name == "esc" then return "cancel" end
	if key.name == "tab" then
		d.focus = (d.focus - 1 + (if key.shift then -1 else 1)) % #d.fields + 1
		return nil
	end
	if key.name == "enter" then
		if d.focus < #d.fields and not key.meta then d.focus += 1; return nil end
		return "submit"
	end
	local _, err = Input.key(d.fields[d.focus].input, key)
	d.error = err
	return nil
end

-- The dialog as a modal overlay for the block's layer.
function M.node(d)
	local body = {}
	for i, f in d.fields do
		local props = Input.props(f.input)
		props.key, props.role, props.placeholder = "input", if i == d.focus then "mission.fieldOn" else "mission.field", f.placeholder
		props.actions = { click = "field=" .. tostring(i) }
		table.insert(body, ui.node("col", { key = "f" .. f.id, role = "mission.formField" }, {
			ui.node("text", { key = "label", text = f.label .. (if f.required then "" else " (optional)"), role = "mission.fieldLabel" }),
			ui.node("input", props),
		}))
	end
	if d.note then table.insert(body, ui.node("text", { key = "note", text = d.note, role = "mission.formNote" })) end
	if d.error then table.insert(body, ui.node("text", { key = "error", text = d.error, role = "mission.notice" })) end
	local ready = M.missing(d) == nil
	return ui.node("col", { key = "layer" }, {
		ui.node("overlay", { key = "dialog", head = d.title, modal = true, foot = "foot", size = { 0.5, 0.5 } }, {
			ui.node("col", { key = "body", role = "mission.form" }, body),
			ui.node("row", { key = "foot", role = "mission.formButtons" }, {
				ui.button("Cancel", { key = "cancel", variant = "quiet", actions = { click = "dialog=cancel" } }),
				ui.button(d.submit, { key = "submit", variant = "primary", disabled = not ready, actions = { click = "dialog=submit" } }),
			}),
		}),
	})
end

do
	local d = M.new("goal", { issues = { "o/r#1" } })
	assert(M.missing(d) == 1, "ui.dialog.missing self-check")
	M.key(d, { name = "a", text = "a" })
	assert(M.key(d, { name = "enter" }) == nil and d.focus == 2 and M.key(d, { name = "enter" }) == "submit", "ui.dialog.key self-check")
	assert(M.values(d).title == "a" and M.missing(d) == nil and M.node(d) ~= nil, "ui.dialog.values self-check")
end

return M
