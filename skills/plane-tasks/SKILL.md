---
name: plane-tasks
description: Use at the start of every task in a Tern pane to track it in the local Plane (plane MCP tools), and whenever you need the user's input, finish, or hand off work.
---

# Track your work in Plane

The user follows every agent's work in their local Plane (workspace `jack`, http://localhost:8090) and replies there instead of in your pane. Keep your work item current so they never have to come looking.

Only do this when `$TERN_PANE` is set (you run in Tern) and the `plane` MCP tools are available, and only as the main agent the user talks to: a subagent given a slice of work by another agent skips it. Skip it for questions and one-off answers that change nothing.

## Contract (Overseer reads these fields; keep them exact)

| What | Field | Value |
|---|---|---|
| Your work item | `external_source` / `external_id` | `tern` / `$TERN_PANE` |
| Your comments | `external_source` / `external_id` | `tern-agent` / `$TERN_PANE` |
| You need the user | label | `needs-you` |

You act in Plane as the user `omp`, not as the user. Comments without `external_source` are the user's. Their replies may reach you as a new prompt; treat them as instructions for this work item.

## 1. Find the project

```sh
repo=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
branch=$(git branch --show-current)
```

- Not in a Git repository: use project `Personal`.
- Else the project name is `$repo` with every character other than letters, digits, `_` and space replaced by a space (`tern-plugins` → `tern plugins`); Plane rejects `-` and `.` in names. Worktrees count as their repository.
- `project` → `list`, match the name exactly. Missing: `project` → `create` with that name, an identifier of its letters and digits, upper-cased, at most 12 characters (`TERNPLUGINS`), and `project_lead` set to the user's id (`member` → `list_workspace` with `email: "jack@acme.ml"`) so they become a member and see it. If the identifier is taken, replace its last character with a digit.

## 2. Start

- The user named a work item (`DASH-12`): `workitem` → `retrieve_by_identifier`, then `update` it with `external_source: "tern"`, `external_id: "$TERN_PANE"` and state `In Progress`.
- Otherwise `workitem` → `create` in the project: a short imperative title, state `In Progress`, the same `external_source` / `external_id`, and a `description_html` of two or three sentences on the goal.
- Then comment once (see Comments): what you're about to do, plus `repo / branch`.

State ids come from `state` → `list` for the project (`Todo`, `In Progress`, `Done`, `Cancelled`).

## 3. While working

- Comment at real milestones only: a decision made, a plan changed, a PR opened (include the link). Not every step.
- **You need the user** (a question, an approval, a choice): post the question as a comment, self-contained with the options and your recommendation, then add the `needs-you` label (`label` → `list`, `create` it if missing, then `workitem` → `manage_label`). Ask in your pane as usual too. Remove the label as soon as you have the answer.
- A follow-up worth doing later: create a separate work item in state `Todo`, without `external_source`, and mention it in a comment.

## 4. Finish

- Done: comment with the outcome (what changed, how it was verified, PR link), remove `needs-you`, set state `Done`.
- Stopping without finishing: comment what's left, set state `Todo`, and clear the link with `external_source: ""` and `external_id: ""` so it no longer points at your pane.

## Comments

`workitem_comment` → `create` with `comment_html` (simple HTML: `<p>`, `<ul>`, `<code>`, `<a>`), `external_source: "tern-agent"`, `external_id: "$TERN_PANE"`. Keep each to a few lines; the user reads them at a glance.

## If Plane is unreachable

Say so once in your pane and carry on with the task. Never block work on tracking.
