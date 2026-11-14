# Mission control: tasks and agents, built into Overseer

Date: 2026-11-14. Status: draft for review. Replaces the Huly setup (PERS-1)
and supersedes `2026-11-12-tasks-design.md`.

## Problem

Agents work across many repositories. You need one place, inside Tern, that
shows what needs you, what every agent is doing, and what's planned, and that
agents keep current themselves. Huly does this but is heavy (≈4.7 GB, 14
containers), mostly features you don't use, and needs workarounds: one shared
`omp` account, a formatting proxy, membership scripts, comment polling.

## Decisions

| Question | Decision |
|---|---|
| Where it lives | Inside Tern: a **Mission control** block, plus the sidebar |
| First view | **Needs you**: questions and decisions waiting on you, answered inline |
| Agent access | One shared MCP server over HTTP (`overseer-server`), custom tools |
| Storage | SQLite (`node:sqlite`, WAL), one file |
| Who runs the server | Overseer: starts it, restarts it when it dies |
| Agent identity | The pane, sent as a header; the server finds the omp session from it |
| Web app | None |

## 1. Architecture

```mermaid
flowchart LR
  A[omp agents] -->|MCP over HTTP, X-Tern-Pane| S[overseer-server :8095]
  S --> DB[(overseer.db)]
  O[Overseer window.luau] -->|tern.fetch: state, answers, acks| S
  O -->|cx.agents:ask| A
  O --> MC[Mission control block]
  O --> SB[Sidebar]
```

- `server/` in this repo: TypeScript run by Bun (installed), using
  `@modelcontextprotocol/sdk` (streamable HTTP) and `bun:sqlite`. One process,
  bound to `127.0.0.1:8095`.
- Every request needs `Authorization: Bearer <token>`; the token is generated
  on first start into the plugin data directory (mode 600). omp reads it with
  a `!cat` header. Other local programs can't write tasks without it.
- Overseer starts the server with `tern.process.run` when the window starts,
  checks `GET /health` every tick, and restarts it after two failed checks
  (logged to `ops.log`).

## 2. Identity

omp's config for every session:

```json
"overseer": { "type": "http", "url": "http://127.0.0.1:8095/mcp",
  "headers": { "X-Tern-Pane": "${TERN_PANE}",
               "Authorization": "!printf 'Bearer %s' \"$(cat <data>/token)\"" } }
```

The server maps pane → omp session (`tern process` + the open session file,
else `--resume`/`--restore`, as `huly/bridge.cjs` does today), cached per pane.
Tasks belong to the session, so they survive Tern restarts. Repository and
branch come from the pane's working directory.

## 3. Data

| Table | Columns |
|---|---|
| `goals` | id (`G-3`), title, body (Markdown), coordinator (session), status (`active` · `done` · `dropped`), created |
| `tasks` | id (`T-12`), goal (optional), title, body (Markdown), repo, branch, worktree, pr, status (`todo` · `ready` · `doing` · `done` · `failed` · `dropped`), session, started_by (session, for workers), created, updated |
| `deps` | task, needs (task): `task` becomes `ready` once every `needs` is `done` |
| `events` | id, task, author (`you` · a session id · `overseer`), kind (`note` · `question` · `answer` · `message` · `done` · `status`), body (Markdown), options (JSON, questions only), to_task (messages only), created, delivered |

- A task is **waiting** while it has a question with no answer after it.
- Agent state (working, idle, gone) is not stored: Overseer knows it live from
  Tern and joins it at display time.

## 4. MCP tools

Modelled on Orca's orchestration (runs, tasks, workers, inbox, `ask`,
`worker_done`), built for omp.

**Every agent**

| Tool | Does |
|---|---|
| `task_start` | Creates a task for the calling session, or takes `id` to pick one up (a worker's brief names it); status `doing` |
| `task_note` | A decision, a plan change, a PR (sets `pr`). Doubles as a heartbeat |
| `ask_user` | A question with numbered options and a recommended one; the task shows in Needs you. The only way to reach you: agents never message you any other way |
| `message` | To another task's agent (`T-12`), or `@goal` (every agent on the caller's goal), across repositories |
| `task_done` | Exactly once: `succeeded` (outcome, files changed) or `failed` (what's left). A worker's `done` also reaches its coordinator |
| `task_add` | A task for later, in any repository, optionally under a goal and depending on other tasks |
| `task_list` | By goal, repository, status, or `mine` |

**Coordinators** (any agent becomes one by creating a goal)

| Tool | Does |
|---|---|
| `goal_create` | A goal and its tasks across repositories, with dependencies; the caller is its coordinator |
| `worker_start` | Starts an omp agent on a `ready` task: Overseer creates a worktree for it (`wt switch --create`, branch named after the task) and opens omp there with a brief naming the task |
| `inbox` | Waits (up to a timeout) for the goal's `done` events, questions and messages; returns them and marks them handled |
| `worker_stop` | Stops a worker; its task goes back to `ready` |

**Sensible launching** (enforced by the server, not left to the prompt):

- Writing tasks always get a new worktree, so parallel workers never share a checkout. Tasks marked `readonly` (research, review) may run in the repository's checkout.
- At most 4 workers per goal at once (setting), and workers can't start workers of their own.
- Only `ready` tasks can be started: dependencies done, no worker on it.
- Every start and stop is logged on the goal and shown in Mission control, with Stop.
- When a goal's last task finishes, its worktrees stay for review; Overseer's existing Delete removes them.

Descriptions carry the rules (when to ask, keep notes short, decisions go to
you), so a short `AGENTS.md` note replaces the `huly-tasks` skill.

## 5. Delivery to agents

- Your answers, and messages from other agents, are queued as events with
  `delivered` empty.
- Overseer fetches the queue each tick, sends each to its task's session pane
  with `cx.agents:ask`, then acks it (`POST /events/<id>/delivered`). A failed
  send stays queued.
- Agent-to-agent messages reach one agent at most once per 2 minutes, bundled.
  Yours go at once.
- `worker_start` is carried out by Overseer too: the server queues a start
  request, Overseer creates the worktree (Worktrunk, as New worktree does) and
  opens omp there with `cx.agents:start`, then reports the pane back.
- Coordinators wait with `inbox` instead of being prompted, so a finishing
  worker doesn't interrupt them mid-turn.

## 6. Mission control block

A plugin block (`palette › Mission control`, a key binding), full height in a
tab of its own. Three sections, top to bottom:

1. **Needs you**: each waiting task as a card: repo · task title, the question
   rendered as Markdown, options as buttons (recommended one marked), and a
   reply field. Answering records it and delivers it; the card leaves.
2. **Working**: tasks in `doing`, grouped under their goal (with its
   progress, e.g. 3 of 5 done) or under No goal; each row: live dot, repo,
   title, last note (one line), how long ago; a worker row has Stop. Enter or click goes to the agent's pane; `o`
   opens the task's thread.
3. **Todo**: collapsed count; expands to a list. `n` adds a task.

A task's **thread** (all its events, newest last, Markdown) opens beside the
block, with a reply field.

Sidebar: a **Needs you N** line at the top (click opens Mission control),
and agent rows show their task (`idle · T-12 · title`), as today.

Keys: `↑↓` select, `↵` open/go, `1`–`9` pick an option, `r` reply, `n` new task,
`o` thread, `Esc` back.

## 7. Migration and cutover

1. Build and run alongside Huly.
2. Import open Huly issues (title, description, comments) into tasks with a
   one-off script.
3. Switch `AGENTS.md` to the Overseer tools; remove the `huly` MCP entry.
4. Remove Huly as PERS-1 describes; delete `huly.luau`, `huly/`,
   `skills/huly-tasks/`.

## 8. Out of scope (v1)

Due dates, priorities, search, a web view, other people, workers on other
machines, agents other than omp as workers.

## Risks

- **The server is a new moving part.** Overseer's health check restarts it;
  SQLite keeps data safe across crashes.
- **`${TERN_PANE}` header expansion:** untested. Fallback: tools take an
  optional `session` argument, read by the agent from `$PI_SESSION_ID`.
- **Session lookup relies on omp keeping its session file open** (and
  `--resume`/`--restore` as fallback), as the Huly bridge does today.
- **Rich input in a block:** Tern blocks support text fields and buttons
  (Overseer's forms use them); long replies are written in the thread's field.

## Verification

1. Server: start, health, token rejection, each tool through a real MCP client.
2. An omp agent started in Tern creates a task, asks a question; it appears in
   Needs you within a second; answering delivers it to that agent.
3. Tern restart: the task stays linked to its resumed session.
4. Two agents in different repositories exchange one `message`.
5. A coordinator creates a goal across two repositories with one dependency,
   starts the ready task's worker in a new worktree, waits with `inbox`, and
   starts the dependent task once the first is done.

## Estimate

About 5 days: server and tools 1.5 days, delivery, identity and worker
starts 1, Mission control block and sidebar 1.5, migration and cutover 0.5,
a real multi-repo goal as the end-to-end test 0.5.
