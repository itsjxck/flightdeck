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
| `Branch` | `git branch --show-current` |
| `PR` | The pull request URL, once there is one |

## 1. Find the project

```sh
repo=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
```

- Not in a Git repository: project `Personal`.
- Else the project named `$repo`. Worktrees count as their repository.
- `list_projects`; match the name exactly. Missing: `create_project` with that name and an identifier of its letters, upper-cased, at most 5 characters (`overseer` → `OVERS`); if taken, change the last letter. Then make the user a member, or they won't see it: `cd ~/projects/tern-plugins/overseer && NODE_OPTIONS=--no-experimental-webstorage npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/join-projects.cjs'`.

Huly answers lookups of something you just created a moment late: if an issue you just made is "not found", wait a second and retry.

## 2. Start

- The user named an issue (`OVERS-12`): `start_work` on it (it moves it to In Progress and assigns it to you).
- Otherwise `create_issue` in the project: a short imperative title, `statusName: "In Progress"`, and a description of two or three sentences on the goal; then `update_issue` with `assignee: "omp agent"`.
- Then `set_custom_fields`: `Tern pane`, `Agent state: "Working"`, `Branch`.
- Then comment once (see Comments): what you're about to do.

## 3. While working

- Comment at real milestones only: a decision made, a plan changed, a PR opened. Not every step.
- **You need the user** (a question, an approval, a choice): post the question as a comment, self-contained, with numbered options and your recommendation first; set `Agent state: "Waiting for you"` and hand the issue to them with `update_issue` `assignee: "Jack Adam"`. Ask in your pane as usual too. Once answered: `Agent state: "Working"`, `assignee: "omp agent"`.
- A PR opened: set `PR`.
- A follow-up worth doing later: `create_issue` in state `Todo`, no custom fields, and mention it in a comment.

## 4. Finish

- Done: comment the outcome (what changed, how it was verified, the PR if any); `update_issue` `statusName: "Done"`; then `Agent state: "Finished"`, `Tern pane: null`. Don't use `finish_work`: its summary isn't formatted.
- Stopping without finishing: comment what's left, status `Todo`, `assignee: null`, `Agent state: null`, `Tern pane: null`.

## Comments

Never use `add_comment`: it stores Markdown as literal text, so Huly shows `**` and loses line breaks. Post Markdown through the helper, which converts it to Huly's rich text:

```sh
cd ~/projects/tern-plugins/overseer && NODE_OPTIONS=--no-experimental-webstorage \
  npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/comment.cjs OVERS-12' <<'EOF'
**Decided:** …

- one point per bullet
EOF
```

Structure each comment for a glance: a bold lead-in (**Started**, **Decided**, **Question**, **Done**), short paragraphs separated by blank lines, bullets for lists, numbered lists for options. A few lines at most.

## If Huly is unreachable

Say so once in your pane and carry on with the task. Never block work on tracking.
