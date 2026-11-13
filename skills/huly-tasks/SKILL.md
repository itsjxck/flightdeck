---
name: huly-tasks
description: Use at the start of every task in a Tern pane to track it in the local Huly (huly MCP tools), and whenever you need the user's input, finish, or hand off work.
---

# Track your work in Huly

The user watches every agent's work on their local Huly board (workspace `jack`, http://localhost:8087), which updates live, and replies there instead of in your pane. Keep your issue current so they never have to come looking.

Only do this when `$TERN_PANE` is set (you run in Tern) and the `huly` MCP tools are available, and only as the main agent the user talks to: a subagent given a slice of work by another agent skips it. Skip it for questions and one-off answers that change nothing.

You act in Huly as the user `omp`. Comments by anyone else are the user's. Their replies may reach you as a new prompt; treat them as instructions for that issue.

## Contract (Overseer reads these fields; keep them exact)

Custom fields on every issue, set with `set_custom_fields` (field name → value; `null` clears):

| Field | Value |
|---|---|
| `Tern pane` | `$TERN_PANE`, while you work on the issue; `null` once you stop |
| `Agent state` | `Working`, `Waiting for you`, `Finished` (Overseer also sets `Idle` and `Gone`) |
| `Question` | What you need from the user, self-contained; `null` once answered |
| `Branch` | `git branch --show-current` |
| `PR` | The pull request URL, once there is one |

## 1. Find the project

```sh
repo=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
```

- Not in a Git repository: project `Personal`.
- Else the project named `$repo`. Worktrees count as their repository.
- `list_projects`; match the name exactly. Missing: `create_project` with that name and an identifier of its letters, upper-cased, at most 5 characters (`overseer` → `OVERS`); if taken, change the last letter. Then make the user a member, or they won't see it: `cd ~/projects/tern-plugins/overseer && npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/join-projects.cjs'`.

Huly answers lookups of something you just created a moment late: if an issue you just made is "not found", wait a second and retry.

## 2. Start

- The user named an issue (`OVERS-12`): `start_work` on it.
- Otherwise `create_issue` in the project: a short imperative title, `statusName: "In Progress"`, and a description of two or three sentences on the goal.
- Then `set_custom_fields`: `Tern pane`, `Agent state: "Working"`, `Branch`.
- Then `add_comment` once: what you're about to do.

## 3. While working

- Comment at real milestones only: a decision made, a plan changed, a PR opened. Not every step.
- **You need the user** (a question, an approval, a choice): set `Question` to the question with its options and your recommendation, and `Agent state: "Waiting for you"`. Ask in your pane as usual too. Once answered: `Question: null`, `Agent state: "Working"`.
- A PR opened: set `PR`.
- A follow-up worth doing later: `create_issue` in state `Todo`, no custom fields, and mention it in a comment.

## 4. Finish

- Done: `finish_work` with a summary (what changed, how it was verified) and the PR if any, `statusName: "Done"`; then `Agent state: "Finished"`, `Question: null`, `Tern pane: null`.
- Stopping without finishing: comment what's left, status `Todo`, `Agent state: null`, `Tern pane: null`.

Keep comments to a few lines of Markdown; the user reads them at a glance.

## If Huly is unreachable

Say so once in your pane and carry on with the task. Never block work on tracking.
