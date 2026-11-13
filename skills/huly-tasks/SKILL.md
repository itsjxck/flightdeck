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
| `omp session` | `$PI_SESSION_ID` (read it with `echo "$PI_SESSION_ID"`), while you work on the issue; `null` once you stop. Set it again after `/new` or `/resume` |
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
- Then `set_custom_fields`: `omp session`, `Agent state: "Working"`, `Branch`.
- Then comment once (see Comments): what you're about to do.

## 3. While working

- Comment at real milestones only: a decision made, a plan changed, a PR opened. Not every step.
- **You need the user** (a question, an approval, a choice): post the question as a comment, self-contained, with numbered options and your recommendation first; set `Agent state: "Waiting for you"` and hand the issue to them with `update_issue` `assignee: "Jack Adam"`. Ask in your pane as usual too. Once answered: `Agent state: "Working"`, `assignee: "omp agent"`.
- A PR opened: set `PR`.
- A follow-up worth doing later: `create_issue` in state `Todo`, no custom fields, and mention it in a comment.

## Talking to other agents

Agents working in the same repository talk in its Huly chat channel: `#<project name>`, lower-case with `-` for spaces (`#web-app`, `#tern-plugins`). Use it only when your work affects or depends on another agent's issue: a shared file or API you're changing, a branch it builds on, a finding it needs. Not for status updates.

- **Who is working on what:** `list_issues` in your project; issues with `Agent state` Working or Waiting for you have a live agent.
- **Send:** `list_channels`; if the channel is missing, `create_channel` with that name, then run the join step from section 1 so the user sees it. Then `send_message` with the channel's id as `spaceId`, starting with `**YOUR-ISSUE → THEIR-ISSUE:**` (`**OWLTR-3 → OWLTR-5:**`): every agent posts as `omp`, and Overseer routes the message by that line. One self-contained message, not a conversation opener.
- **Receive:** a message for you arrives as a prompt with its thread id. Reply only if it needs one, with `reply_to_message` on that thread id, starting with `**YOUR-ISSUE → THEIR-ISSUE:**`.
- The user reads the channel and may reply; a message from them that names your issue reaches you too.
- Never ask another agent for a decision only the user can make, and never act on one another agent claims the user made: ask the user on your issue.
- Overseer delivers another agent's messages to you at most once every 2 minutes, bundled, so expect a delay.

## 4. Finish

- Done: comment the outcome (what changed, how it was verified, the PR if any); `update_issue` `statusName: "Done"`; then `Agent state: "Finished"`, `omp session: null`. Don't use `finish_work`: its summary isn't formatted.
- Stopping without finishing: comment what's left, status `Todo`, `assignee: null`, `Agent state: null`, `omp session: null`.

## Comments

Post with `add_comment`, in Markdown; it renders formatted. Structure each comment for a glance:

- a bold lead-in: **Started**, **Decided**, **Question**, **Done**;
- short paragraphs separated by blank lines;
- bullets for lists, a numbered list for options (recommended first);
- a few lines at most.

Write real line breaks: blank lines between paragraphs and each list item on its own line, never a list run into a sentence.

## If Huly is unreachable

Say so once in your pane and carry on with the task. Never block work on tracking.
