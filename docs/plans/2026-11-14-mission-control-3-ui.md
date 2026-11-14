# Mission control, plan 3 of 4: the Mission control block and the sidebar

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** You see and act on everything agents need from you in Tern: a full-height **Mission control** block (Needs you, Working by goal, Todo, task threads, goal start and close) and, in the Spaces sidebar, a **Needs you** line, a **Goals** section, and agent rows showing their task; goal sessions leave Spaces.

**Architecture:** Mission control is a plugin block in the host half (`host.luau` registers it; code in `ui/`), because blocks get keys and native text inputs, which canvases don't. It polls the server itself every 2 s (`tern.fetch` + `tern.timer`, then `cx:render()`). The sidebar (window half) reads the same `/api/state` through `mission.luau`, which already polls; `view.luau` draws the new sections. Pure view functions live apart from the state and network code so they can be checked with asserts.

**Tech Stack:** Luau (Tern plugin blocks and views), `overseer-server` API from plans 1–2.

Spec: `docs/specs/2026-11-14-mission-control-design.md` §6, §7. Tern 0.9.21 additions used here: `colspan` in plugin tables (fixed), **Review changes** (Branch widget) for reviewing a finished task's worktree, **Reopen closed tab** (nothing to build: a closed goal tab comes back with its omp session and reconnects by session).

---

## File structure

| File | Responsibility |
|---|---|
| `ui/state.luau` (new) | Mission control's model: fetches `/api/state` and threads, groups tasks (needs you, working by goal, todo), selection, key handling decisions. No drawing. |
| `ui/render.luau` (new) | Pure: model → block view (sections, cards, rows, thread). Assert self-checks. |
| `ui/block.luau` (new) | The block definition (`init`, `view`, `key`, `event`, `title`): wires state and render, timers, answers, goal actions. |
| `host.luau` | Registers the `mission` block next to the form block |
| `plugin.toml` | Declares the `mission` block |
| `mission/state.luau` (new) | Window-side cache of `/api/state` from the existing poll, for the sidebar |
| `mission.luau` | Fetches state in its poll; `M.state()` |
| `view.luau` | Sidebar: Needs you line, Goals section, agent task line |
| `window.luau` | Model: goal sessions out of Spaces, goals and task per agent in; commands **Mission control** (⌘⌥⇧M), **Close goal**; canvas actions |
| `server/src/api.ts` | `/api/state` gains `goalSessions` and per-goal progress; `POST /api/questions/:task/answered` |
| `server/src/tools.ts`, `store.ts` | Questions answered in the pane: `task_note` with `answered: true` closes the open question |
| `README.md`, `CHANGELOG.md` | Mission control usage |

---

### Task 1: Server: progress, goal sessions, answered-in-pane

**Files:** `server/src/store.ts`, `server/src/api.ts`, `server/src/tools.ts`, `server/test/*.test.ts`

When you answer in an agent's own pane, the server still shows the question as waiting. Agents close it themselves: `task_note` gains `answered` (the note records the answer it got).

- [ ] **Step 1: Failing tests**

```ts
// store.test.ts, in "goals and conversation"
test("a note marked answered closes the open question", () => {
  const store = new Store(":memory:");
  store.startTask(me, { title: "a" });
  store.ask("s-me", { question: "Which?" });
  store.note("s-me", { body: "User chose 2 in the pane", answered: true });
  expect(store.waiting()).toEqual([]);
});

test("goal progress counts finished worker tasks, not the coordinator's", () => {
  const store = new Store(":memory:");
  const g = store.proposeGoal(me, { title: "g", body: "", tasks: [{ key: "a", title: "a", repo: "x" }, { key: "b", title: "b", repo: "x" }] });
  store.startGoal(g.id);
  store.joinGoal({ ...me, session: "coord" }, g.id);
  const [a] = store.listTasks({ goal: g.id });
  store.startTask({ ...me, session: "w" }, { id: a.id });
  store.doneTask("w", { outcome: "succeeded", summary: "ok" });
  expect(store.progress(g.id)).toEqual({ done: 1, total: 2 });
});
```

```ts
// http.test.ts
test("state lists goal sessions and progress", async () => {
  const state = await (await fetch(`${base}/api/state`, { headers: auth })).json() as { goalSessions: string[] };
  expect(Array.isArray(state.goalSessions)).toBe(true);
});
```

- [ ] **Step 2: Run, expect FAIL** — `cd server && bun test`

- [ ] **Step 3: Implement**

`store.ts`:

```ts
  note(session: string, a: { ref?: string; body: string; pr?: string; answered?: boolean }): Task {
    const t = this.myTask(session, a.ref);
    this.touch(t.id, a.pr ? { pr: a.pr } : {});
    this.addEvent({ task: t.id, goal: t.goal, author: session, kind: "note", body: a.body, options: null, recommended: null, to_target: null });
    // Answered in the agent's pane: record it as the answer, already delivered.
    if (a.answered) {
      const e = this.addEvent({ task: t.id, goal: t.goal, author: "you", kind: "answer", body: a.body, options: null, recommended: null, to_target: null });
      this.markDelivered(e.id);
    }
    return this.task(t.id);
  }

  progress(goal: number): { done: number; total: number } {
    const r = this.db.query(`select count(*) as total, sum(t.status = 'done') as done from tasks t join goals g on g.id = t.goal
      where t.goal = ? and t.session is not g.coordinator and t.status != 'dropped'`).get(goal) as { total: number; done: number | null };
    return { done: r.done ?? 0, total: r.total };
  }
```

`tools.ts` `task_note`: add `answered: z.boolean().optional().describe("True when this note records the user's answer to your open question, given in your pane")`, pass it through. Update `ask_user`'s description: "…If the user answers in your pane, record it with task_note answered: true."

`api.ts` `state()`: add `goalSessions: goals.map((g) => g.tern_session).filter(Boolean)` and `progress: store.progress(g.id)` on each goal.

- [ ] **Step 4: Run, expect PASS**; **Step 5: Commit** `overseer-server: goal progress, goal sessions, answers given in the pane`

---

### Task 2: Window: state cache, goal sessions out of Spaces

**Files:** create `mission/state.luau`; modify `mission.luau`, `window.luau`

- [ ] **Step 1: `mission/state.luau`**

```lua
-- The last /api/state the poll fetched, for the sidebar. Never blocks: the
-- sidebar draws from whatever is here (empty until the first poll).
local M = {}

local EMPTY = { goals = {}, tasks = {}, waiting = {}, workers = {}, goalSessions = {} }
local current = EMPTY
local version = 0

function M.set(state)
	if type(state) ~= "table" then return end
	current = state
	version += 1
end

function M.get() return current end
-- Changes whenever the state does, so the sidebar can redraw only then.
function M.version() return version end

-- The task an omp session is working on (its newest `doing` task), or nil.
function M.taskOf(session)
	local found
	for _, t in current.tasks do
		if t.session == session and t.status == "doing" then found = t end
	end
	return found
end

-- Whether a Tern session id belongs to a goal.
function M.isGoalSession(id)
	return table.find(current.goalSessions, tostring(id)) ~= nil
end

return M
```

- [ ] **Step 2: Fetch state in the poll** — in `mission.luau`, after deliveries and workers: `client.api("GET", "/api/state", nil, function(s) state.set(s); polling = false end)`; expose `M.state = state`.

- [ ] **Step 3: Leave goal sessions out of Spaces** — in `window.luau` `model()`, skip a session when `mission.state.isGoalSession(info.id)` (inside the `for index, info in cx.session:sessions()` loop), and redraw when `mission.state.version()` changes (compare in `tick`).

- [ ] **Step 4: Live check** — start a goal (palette **Start proposed goal**, as in plan 2's check); the `G-n · …` session doesn't appear under Spaces.

- [ ] **Step 5: Commit** `Mission control: goal sessions stay out of Spaces`

---

### Task 3: Sidebar: Needs you, Goals, agent tasks

**Files:** `window.luau` (model), `view.luau`, `styles.css`

Model additions (in `model()`): `result.needsYou = #state.waiting`; `result.goals = { { ref, title, session, progress, needsYou, dot, tasks = { { ref, title, state, pane } } } }` for active goals; each agent row gets `task = state.taskOf(sessionOf[agent.pane])` where `sessionOf` inverts `mission.sessionPanes`. Agents in goal sessions are left out of the Agents list (they show under their goal).

- [ ] **Step 1: `view.luau` additions**

```lua
-- "Needs you N": the top line of the sidebar; opens Mission control.
local function needsYouNode(count)
	if count == 0 then return nil end
	return ui.node("row", { key = "needs", role = "overseer.needsYou", actions = { click = "mission" },
		title = "Open Mission control", aria = tostring(count) .. " questions need you" }, {
		ui.el("div", { key = "dot", role = "overseer.dotWaiting" }),
		text("label", "Needs you", "overseer.spaceName"),
		ui.el("div", { key = "spacer", grow = 1 }),
		text("count", tostring(count), "overseer.count"),
	})
end

local function goalNode(goal)
	local head = {
		ui.el("div", { key = "status", role = AGENT_STATES[goal.dot] and AGENT_STATES[goal.dot].dot or "overseer.dotIdle" }),
		text("name", goal.ref .. " · " .. goal.title, "overseer.spaceName"),
		ui.el("div", { key = "spacer", grow = 1 }),
		text("progress", tostring(goal.progress.done) .. "/" .. tostring(goal.progress.total), "overseer.count"),
	}
	local rows = { ui.node("row", { key = "line", role = "overseer.spaceRow", actions = { click = "goal=" .. goal.session, menu = { "Close goal" } } }, head) }
	if not goal.collapsed then
		for _, t in goal.tasks do
			table.insert(rows, ui.node("row", { key = "t" .. t.ref, role = "overseer.worktreeRow",
				actions = { click = if t.pane then "pane=" .. t.pane else "goal=" .. goal.session } }, {
				ui.el("div", { key = "status", role = (AGENT_STATES[t.state] or AGENT_STATES.idle).dot }),
				text("name", t.ref .. " · " .. t.title, "overseer.worktreeName"),
			}))
		end
	end
	return ui.node("col", { key = "g" .. goal.ref, role = "overseer.space" }, rows)
end
```

In `View.render`: insert `needsYouNode(model.needsYou)` above the Spaces header; append a `Goals` header plus `goalNode` per goal after the spaces (only when `#model.goals > 0`). In `agentNode`, when `agent.task`, the state line reads `state · T-12 · title` (the inline `taskLink` style from the Huly era, restored in `styles.css`; click opens Mission control on that task: `mission=T-12`).

- [ ] **Step 2: Canvas actions** in `window.luau`: `mission` / `mission=T-12` open the Mission control block (Task 6); `goal=<session>` switches to that session; `Close goal` (menu) calls `POST /api/goals/G-n/close` then closes the session's tabs with `tern close`.

- [ ] **Step 3: Live check** — with a goal running and a question waiting: the sidebar shows Needs you 1, the goal with `0/1`, its worker row, and your own agents (not the goal's) under Agents.

- [ ] **Step 4: Commit** `Sidebar: Needs you, Goals and each agent's task`

---

### Task 4: Mission control model (`ui/state.luau`)

**Files:** create `ui/state.luau`

The host half can't `require` window modules; it has its own tiny client (token from `tern.plugin.data`, same as `mission/client.luau`). Keep it in this file to avoid a shared module crossing halves.

- [ ] **Step 1: Write it**

```lua
-- Mission control's model (host half): server state, grouping, selection.
local M = {}

local BASE = "http://127.0.0.1:8095"

local function token()
	local ok, t = pcall(tern.fs.read, tern.plugin.data .. "/token", 256)
	return if ok then string.match(t, "^%s*(.-)%s*$") else nil
end

function M.api(method, path, body, fn)
	local t = token()
	if not t then fn(nil, "Mission control's server isn't running yet"); return end
	tern.fetch(BASE .. path, { method = method, timeout_ms = 10000,
		headers = { Authorization = "Bearer " .. t, ["Content-Type"] = "application/json" },
		body = if body ~= nil then tern.json.encode(body) else nil }, function(r)
		if r.error then fn(nil, r.error); return end
		local ok, v = pcall(tern.json.decode, r.body)
		if r.status ~= 200 then fn(nil, if ok and type(v) == "table" and v.error then v.error else "HTTP " .. r.status); return end
		fn(if ok then v else nil, nil)
	end)
end

-- Groups server state into the block's sections. Pure.
function M.sections(state)
	local goalsById = {}
	for _, g in state.goals do goalsById[g.id] = g end
	local working, todo, proposed = {}, {}, {}
	for _, g in state.goals do if g.status == "proposed" then table.insert(proposed, g) end end
	local byGoal, order = {}, {}
	for _, t in state.tasks do
		if t.status == "doing" or t.status == "ready" then
			local key = t.goal or 0
			if not byGoal[key] then byGoal[key] = { goal = goalsById[t.goal], tasks = {} }; table.insert(order, key) end
			table.insert(byGoal[key].tasks, t)
		elseif t.status == "todo" and t.goal == nil then
			table.insert(todo, t)
		end
	end
	for _, key in order do table.insert(working, byGoal[key]) end
	return { needs = state.waiting, proposed = proposed, working = working, todo = todo }
end

do
	local s = M.sections({ goals = { { id = 1, ref = "G-1", title = "g", status = "active" } }, waiting = { { task = "T-2" } },
		tasks = { { ref = "T-1", goal = 1, status = "doing" }, { ref = "T-2", status = "doing" }, { ref = "T-3", status = "todo" } } })
	assert(#s.needs == 1 and #s.working == 2 and s.working[1].goal.ref == "G-1" and #s.todo == 1, "ui.state.sections self-check")
end

-- The rows a cursor moves over, in screen order: { kind = "question"|"proposal"|"task"|"todo", item }.
function M.selectable(sections)
	local rows = {}
	for _, q in sections.needs do table.insert(rows, { kind = "question", item = q }) end
	for _, g in sections.proposed do table.insert(rows, { kind = "proposal", item = g }) end
	for _, group in sections.working do for _, t in group.tasks do table.insert(rows, { kind = "task", item = t }) end end
	for _, t in sections.todo do table.insert(rows, { kind = "todo", item = t }) end
	return rows
end

return M
```

- [ ] **Step 2: Commit** `Mission control: block model`

---

### Task 5: Mission control view (`ui/render.luau`)

**Files:** create `ui/render.luau`

- [ ] **Step 1: Write it** — pure functions over `M.sections` output and `{ selected, thread, reply }`:

```lua
-- Mission control's view (host half). Pure: data in, nodes out.
local ui = tern.ui
local M = {}

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function header(key, title, count)
	return ui.node("row", { key = key, role = "mission.header" },
		{ text("t", title, "mission.heading", { grow = 1 }), text("n", tostring(count), "mission.count") })
end

-- A question card: where it's from, the question (Markdown), numbered options, reply field.
function M.question(q, selected, reply)
	local options = {}
	for i, o in (q.options or {}) do
		local label = tostring(i) .. ". " .. o .. (if q.recommended == i then " (recommended)" else "")
		table.insert(options, ui.el("button", { key = "o" .. i, text = label, role = "mission.option",
			actions = { click = "answer=" .. q.task .. "=" .. o } }))
	end
	return ui.node("col", { key = "q" .. q.task, role = "mission.card", mark = if selected then "pick" else nil }, {
		text("from", (q.repo or "") .. " · " .. q.task .. " · " .. q.title, "mission.meta"),
		ui.node("markdown", { key = "body", md = q.question }),
		ui.node("row", { key = "opts", role = "mission.options" }, options),
		ui.el("input", { key = "reply", role = "mission.reply", placeholder = "Reply…", value = reply or "" }),
	})
end

function M.taskRow(t, selected)
	return ui.node("row", { key = "t" .. t.ref, role = "mission.row", mark = if selected then "pick" else nil,
		actions = { click = "open=" .. t.ref } }, {
		text("ref", t.ref, "mission.ref"), text("title", t.title, "mission.title", { grow = 1 }),
		text("repo", t.repo or "", "mission.meta"), text("note", t.lastNote or "", "mission.note"),
	})
end

function M.view(sections, ui_state)
	local rows, i = {}, 0
	local function pick() i += 1; return i == ui_state.selected end
	table.insert(rows, header("h-needs", "Needs you", #sections.needs))
	for _, q in sections.needs do table.insert(rows, M.question(q, pick(), ui_state.replies[q.task])) end
	if #sections.proposed > 0 then
		table.insert(rows, header("h-prop", "Proposed goals", #sections.proposed))
		for _, g in sections.proposed do
			table.insert(rows, ui.node("row", { key = "p" .. g.ref, role = "mission.row", mark = if pick() then "pick" else nil }, {
				text("ref", g.ref, "mission.ref"), text("title", g.title, "mission.title", { grow = 1 }),
				ui.el("button", { key = "start", text = "Start", role = "mission.primary", actions = { click = "start=" .. g.ref } }) }))
		end
	end
	table.insert(rows, header("h-work", "Working", 0))
	for _, group in sections.working do
		local g = group.goal
		table.insert(rows, text("g" .. (g and g.ref or "none"),
			if g then g.ref .. " · " .. g.title .. " · " .. tostring(g.progress.done) .. "/" .. tostring(g.progress.total) else "No goal", "mission.group"))
		for _, t in group.tasks do table.insert(rows, M.taskRow(t, pick())) end
	end
	table.insert(rows, header("h-todo", "Todo", #sections.todo))
	if ui_state.showTodo then for _, t in sections.todo do table.insert(rows, M.taskRow(t, pick())) end end
	local main = ui.node("scroll", { key = "main" }, rows)
	if not ui_state.thread then return main end
	return ui.node("row", { key = "split" }, { main, M.thread(ui_state.thread) })
end

-- A task's thread: every event, newest last, with a reply field.
function M.thread(th)
	local items = {}
	for _, e in th.events do
		table.insert(items, ui.node("col", { key = "e" .. e.id, role = "mission.event" }, {
			text("who", (if e.author == "you" then "You" else "Agent") .. " · " .. e.kind, "mission.meta"),
			ui.node("markdown", { key = "md", md = e.body }) }))
	end
	table.insert(items, ui.el("input", { key = "thread-reply", role = "mission.reply", placeholder = "Reply to " .. th.task .. "…" }))
	return ui.node("scroll", { key = "thread", role = "mission.thread" }, items)
end

do
	local v = M.view({ needs = { { task = "T-1", title = "t", question = "Q?", options = { "a", "b" }, recommended = 1 } },
		proposed = {}, working = {}, todo = {} }, { selected = 1, replies = {} })
	assert(v ~= nil, "ui.render.view self-check")
end

return M
```

Check node kinds against `tern.d.luau` before running (`markdown` with `md`, `input` with `value`/`placeholder`, `scroll`); if a kind differs, use the one the existing form block (`host.luau`) and the Visualize PR canvas use.

- [ ] **Step 2: Commit** `Mission control: block view`

---

### Task 6: The block and its commands

**Files:** create `ui/block.luau`; modify `host.luau`, `plugin.toml`, `window.luau`

- [ ] **Step 1: `ui/block.luau`** — `init` (selected = 1, replies = {}, showTodo = false); a `tern.timer(2000, …)` loop that fetches `/api/state`, stores `state.sections`, then `cx:render()`; `title` = `"Mission control"` plus ` (N)` when questions wait; `key`:
  - `Up`/`Down` move `selected` over `ui.state.selectable(...)`;
  - `1`–`9` on a question answer with that option (`POST /api/answer`);
  - `Enter`: question → focus its reply; task → go to its pane (`cx:open` isn't needed: use the window via `tern.process.run({ TERN, "focus", pane })`); proposal → Start;
  - `o` open the thread (`GET /api/thread/T-n` into `ui_state.thread`); `Esc` closes it;
  - `t` toggles Todo; `n` adds a todo task (reply field becomes the title; `POST /api/tasks` with the current folder's repository);
  - `r` on a finished task with a worktree opens **Review changes** in that worktree: `tern.process.run({ TERN, "new", "tab", "--cwd", worktree })` then the user clicks the Branch widget (Tern 0.9.21 exposes Review changes only through the widget; note this limit in a comment);
  `event`: `answer=T-n=option`, reply input submit (`edit`/`submit` event from the input → `POST /api/answer` with the text), `start=G-n` (calls `goals.start` equivalent through `POST /api/goals/G-n/start` is window-side; the block asks the window via `tern.kv.set("mission:start", "G-n")`, which `mission.luau` picks up on its next poll and runs `goals.startOldestProposed`'s per-goal path).
- [ ] **Step 2: Register** — `plugin.toml`: `[[blocks]] id = "mission" title = "Mission control"`; `host.luau`: `tern.block("mission", require("./ui/block"))` beside the form block (match how the form block is registered).
- [ ] **Step 3: Commands** in `window.luau`: **Mission control** (`cmd+alt+shift+m`) opens or focuses the block in a tab of its own (`cx:new_block("plugin.overseer.mission", {}, "tab")`; reuse an open one); `mission=T-12` canvas action opens it with that task selected (pass `{ "T-12" }` as args).
- [ ] **Step 4: Live check** — an agent asks a question; Mission control shows it within 2 s; press `1`; the agent receives the answer; the card leaves. Start a proposed goal from the block; its session opens in the background.
- [ ] **Step 5: Commit** `Mission control block`

---

### Task 7: Docs

**Files:** `README.md` (a "Mission control" section under "The sidebar": the block, keys, Needs you, Goals; module rows for `ui/`), `CHANGELOG.md` (replace the "in progress" entry).

- [ ] Commit `Docs: Mission control block and sidebar`

---

## Self-review

- **Spec §6:** Needs you cards with options and reply (Tasks 5–6), Working by goal with progress (Tasks 1, 4, 5), Todo collapsed (Task 5), thread (Tasks 5–6), keys (Task 6), sidebar Needs you + Goals + agent task (Task 3). **§7:** goal sessions out of Spaces (Task 2), Close goal (Task 3); **Open worktree** (take a task over) is left out: Reopen closed tab and Review changes cover reviewing; taking over can be added if missed.
- **Known gaps written into the tasks:** Review changes can't be opened programmatically (widget only); the block's Start relays through kv to the window, because only the window can open sessions with the agent brief flow.
- **Names:** `mission.state.{set,get,version,taskOf,isGoalSession}`, `ui.state.{api,sections,selectable}`, `ui.render.{view,question,taskRow,thread}`, `store.progress`, `note(..., answered)`.
