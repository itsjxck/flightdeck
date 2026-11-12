# Tasks: one board for you and your agents

Date: 2026-11-12. Status: approved design, not built.

## Problem

With several agents running, nothing shows what each one is working on, which
ones need you, or what you mean to start next. A Notion board was too far away
to keep up to date. The answer has to be visible at a glance inside Tern and
kept current by the agents themselves.

## Decisions

| Question | Decision |
|---|---|
| Where tasks live | One Markdown file, `~/TASKS.md`, read by Tern's built-in board block |
| Lanes | `Todo`, `Doing`, `Done` (Tern's defaults for a new board) |
| Who creates cards | Both: agents add cards for their own work, you add yours |
| Where you look | Overseer's sidebar for the glance, the board block for planning |
| How agents report | A skill telling them to edit the file; no MCP server |
| "Needs you" | Not a lane: Overseer derives it live from the linked agent's state |

## 1. The file

```md
## Todo
- [ ] Think about the auth rewrite #from-agent
  from: dashboard / feat/login

## Doing
- [ ] Fix flaky login test
  pane: 7048041332755

## Done
- [x] Ship overseer 3.0
```

- Lanes are `## ` headings; cards are `- [ ] ` / `- [x] ` lines; indented lines
  under a card are its notes. Checked on Tern 0.9.18: notes don't render as
  cards, tags (`#from-agent`) stay in the card text.
- The one line Overseer reads is a note `pane: <id>`, the agent's
  `$TERN_PANE`. Any other note is for people.
- Overseer only reads the file. Agents and the board block write it.

## 2. Agent skill: `skills/tasks/SKILL.md`

Shipped in this repository; the README says how to link it into omp's, Claude
Code's and Codex's skill folders. It tells an agent:

1. Starting work you were given a card for: move that card to `Doing` and add
   `pane: $TERN_PANE` under it (replace an older `pane:` line).
2. Starting work without a card: add `- [ ] <short title>` to `Doing` with the
   `pane:` note.
3. Something you or the user should look at later: add it to `Todo` with
   `#from-agent` and a `from: <repo> / <branch>` note.
4. Finished: tick the card (`[x]`) and move it to `Done`. Abandoned: remove
   the `pane:` note and move the card back to `Todo`.
5. Edit with a fresh read and a targeted line edit, never by rewriting the
   whole file: other agents and the open board write it too.
6. Create the file with the three headings if it doesn't exist.

Only do this when `$TERN_PANE` is set (the agent runs in Tern).

## 3. Sidebar section

A **Tasks** section in the sidebar's dock, above Agents:

- Header: `Tasks`, then `Todo <n>` (opens the board) and `+` (opens the board
  to add a card). The board opens with `cx.board:open("~/TASKS.md", { how = "tab" })`,
  expanded to an absolute path.
- One row per `Doing` card: status dot, title, and the space its agent is in.
  - Dot and order come from the linked agent (`agentPanes`): waiting first
    (blue halo), then working (pulsing green), then idle (grey), then cards
    whose pane is gone or that have no `pane:` note (hollow, "no agent").
  - Click: a card with a live agent goes to it (`showPane`); any other card
    opens the board.
- At most 8 rows; past that, a `+N more` row opens the board.
- No file, or no `Doing` cards: the header alone, so `Todo <n>` and `+` stay
  reachable.

An agent that is waiting but has no card still shows in Agents as today; Tasks
doesn't duplicate it.

## 4. Reading the file

- Each tick, in its own `separately` callback: `tern.fs.read(path, 256 KiB)`
  (the size cap also refuses FIFOs). If the text equals the last read, stop;
  else parse and redraw. A missing file is an empty board. A read or parse
  failure keeps the last good parse and logs once to Tern's log.
- `tern.fs` has no modification time, so the comparison is on the text; reads
  are native calls and don't count toward the 50 ms budget.
- The parser lives in a new `tasks.luau` (lanes, cards, done flag, `pane`).
  No Luau runtime is installed outside Tern, so its assert-based self-check
  runs once when the module loads (well under 1 ms) and a failure shows in
  Tern's log and `tern plugin list`.
- The rows join into `model(cx)` so the existing signature check decides
  whether the canvas redraws.

## 5. Out of scope

Due dates, priorities, per-repository boards, sync with Notion or Linear,
editing cards from the sidebar, showing an agent's question text (Tern exposes
only its state).

## Risks

- **Lost updates.** Two writers saving the whole file at once lose one edit.
  The skill's targeted edits make this rare; the board block reloads external
  changes. Accepted for a single-user file.
- **Agents not following the skill.** A card without `pane:` shows as "no
  agent" rather than wrong state; nothing breaks.
- **Stale pane ids.** Pane ids end with their pane; such cards show "no agent"
  until moved or updated.

## Verification

1. Parser self-check: the sample file above, an empty file, a file without
   headings, CRLF line endings.
2. Live: a card with `pane:` set to a running agent shows its state and moves
   to the top when the agent asks a question; clicking it focuses that pane.
3. `Todo <n>` and `+` open `~/TASKS.md` as a board block.
4. An omp agent given the skill adds, updates and finishes its own card.
