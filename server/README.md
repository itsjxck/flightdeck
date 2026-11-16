# overseer-server

Mission control's server: tasks, goals, questions, messages and workers for omp agents, in one SQLite file. Overseer starts it (`mission/server.luau`) and talks to it over HTTP; agents use it as an MCP server.

```sh
bun install
bun test                      # every rule and endpoint
bun src/main.ts <data dir>    # what Overseer runs; port 8095 (OVERSEER_PORT)
```

## Modules

| File | Responsibility |
|---|---|
| `src/store.ts` | Schema and every read, write and rule: task statuses, dependencies (`promote`), goals and their coordinator, questions (`waiting`), messages, worker limits, the coordinator inbox, deliveries with the 2-minute agent-message gap. No I/O besides SQLite. Change behaviour here. |
| `src/tools.ts` | The MCP tools agents see. Each resolves its caller, calls `store`, and turns a broken rule into a tool error. Tool descriptions are the agents' instructions. |
| `src/api.ts` | Overseer's JSON API (`/api/*`): state, the backlog (every goal and task), repositories (list, ignore), threads, answers, goal start/session/close, deliveries, worker starts and stops, pane → session lookup. Also the coordinator and worker briefs. |
| `src/identity.ts` | Which omp session a request comes from: `X-Tern-Pane` → `tern process` → the session file the pane's process group holds open (or `--resume`/`--restore`), plus its folder, repository and branch. |
| `src/repos.ts` | Finds Git repositories (breadth-first from `repos.json` roots, default `~`, depth 5, skipping system and build folders; worktrees and nested repositories don't count). `main.ts` scans at start, every 30 minutes and on `POST /api/repos/scan`; `store.syncScanned` records it. |
| `src/github.ts` | GitHub through `gh`: open issues of known repositories (remote → owner/name), comments on linked issues, closing one you chose. Never closes issues on its own. |
| `src/analytics.ts` | The Stats tab: reads new usage (cost, tokens) from omp's session files every 5 minutes by byte offset into `usage`; agent counts the window posts each minute (`agent_samples`, kept 30 days); `analytics()` builds spend, agent and goal/task series for `GET /api/analytics`. |
| `src/main.ts` | `Bun.serve` on 127.0.0.1: `/health` (open), `/mcp` and `/api/*` (bearer token from `<data dir>/token`, created on first start). |

## Data flow

```mermaid
flowchart LR
  A[omp agent] -->|MCP, X-Tern-Pane| T[tools.ts]
  T --> S[store.ts]
  O[Overseer mission/] -->|/api| P[api.ts]
  P --> S
  S --> DB[(overseer.db)]
```

Answers and agents' messages are queued as events; Overseer fetches `/api/deliveries`, sends each to the pane running its session, then acks it. Worker starts are queued the same way (`/api/workers`), and Overseer opens them. Goal lifecycle: proposed → active (started) → finished (the coordinator called `task_done` on its own task) → done (the user closed it) or dropped. Coordinators manage workers: `worker_stop` closes one (a finished task stays finished), `worker_start` on a done or failed task reopens it, switching to its existing branch, with optional `context` added to the brief.

## Conventions

- Ids are integers in SQLite. People and agents see references: goals `G3` (`Store.gid`, `parseGoal`), a goal's tasks `G3.2` numbered within it by `tasks.seq` (the coordinator's own task is `G3.0`), tasks outside goals `T7` (`seq` from the `loose` counter), workers `W5`. `store.tref(id)` and `store.taskId(ref)` convert; goal ids and the `loose` counter only grow (`counters` table), so a number never comes back after the 30-day cleanup. The first release's `T-12` (internal id) and `G-3` are still accepted. Message targets (`events.to_target`) keep the internal `T-<id>` form.
- Rule errors are thrown as `Error` with a message an agent can act on; `tools.ts` and `api.ts` return them, never crash.
- Tests use an in-memory store and an injected clock (`new Store(":memory:", () => clock)`).

## Demo scenarios

`bun scripts/demo.ts` creates three small repositories in `~/projects/overseer-demo` (`demo-payments`, `demo-storefront`, `demo-design-system`) and proposes four goals across them, plus one task for later:

- **Add Apple Pay to checkout**: three tasks in three repos; the storefront task waits for the other two.
- **Dark mode**: two tasks; the first asks you which brand colour to use.
- **Rate-limit login**: one task that asks you how to limit.
- **Order history**: no tasks; its coordinator reads the repos and plans them.

Start one from Mission control. `bun scripts/demo.ts --reset` drops the demo goals and tasks and deletes the repos and their worktrees (`~/worktrees/demo-*`); close any started goal's session with **Close goal** first.
