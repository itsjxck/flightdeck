# Changelog

## 3.0.0 (unreleased)

The Projects panel is now a Spaces sidebar, laid out like herdr's: every Tern session is a space, Git worktrees nest under the space open in their repository, and every running agent is listed at the bottom.

### Changed

- **Spaces replace projects.** Each Tern session in the window is a row, named after the folder of the first terminal in its first tab (following `cd`) until you rename it. Spaces don't need to be Git repositories; there's no list of projects to add or remove.
- **Worktrees nest under their repository's space.** A space open in a Git repository lists the repository's other worktrees beneath it: the space in the primary checkout if there is one, else the first. Spaces open in those worktrees appear as their rows instead of on their own. Rows are one line: status dot, name, uncommitted mark and PR.
- **Worktree sessions are named `repo / branch`** in Tern's session list, including spaces you opened in a worktree yourself, unless you've renamed them.
- **A session whose last tab closes is closed too**, instead of lingering empty (the sidebar, parked in it, kept it open). Locked sessions and the window's last session stay.
- **Confirmations pop up over the tab** (Delete worktree, Close session, Close space) instead of appearing at the top of the panel. Cancel, Esc or a click outside keeps things as they are.
- **One icon size everywhere.** The header's + and ↻, each space's + and chevron, and a worktree's PR link are 20px squares holding a 12px Octicon, 4px apart, in one right-hand column. ↻ is square, so it turns about its centre while refreshing.
- **PR buttons on spaces too.** A space on a branch with a GitHub PR shows the same button as a worktree row; clicking either opens the PR in your default browser. PRs are now looked up for every checked-out branch except the repository's base, so a space working on a feature branch in its main checkout gets one.
- **Agents section.** Every agent block and agent CLI (`omp`, `claude`, `codex`, …) across the window's spaces, with its state (working, waiting, idle). Click one to go to its space and pane. It sits in the canvas's dock, so it stays at the bottom while spaces scroll.
- **Space menu:** Rename space (renames the Tern session; blank names it after its folder again), New worktree, Change base branch and Close space. **+** in the header opens a new space in any folder.
- **Status dots:** grey for an open, quiet session (was green), hollow for a worktree without one, pulsing green while an agent works, haloed blue while one waits for you.
- **Force delete** (ported from upstream 2.3.1). Deleting a worktree with uncommitted changes no longer just refuses: the popup lists the files with line counts and offers Force delete, which runs `wt remove --force`. The helper still rechecks the repository and branch, never touches the primary checkout and always keeps the branch.
- **Creations show progress** (from upstream 2.3.1). A new worktree's row appears as soon as setup starts, with elapsed time and Worktrunk's current step; a hook approval prompt or a minute without output marks it "needs you?" with one notification, and the row opens the setup tab.
- **Operation log** (from upstream 2.3.1). `ops.log` in the plugin data directory records every creation and deletion (duration, outcome, the first warning setup printed), hook-approval waits, budget pauses, tick restarts and plugin reloads. **Show Overseer's operation log** opens it.
- **Keyboard navigation.** <kbd>⌃</kbd><kbd>⌘</kbd><kbd>]</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>[</kbd> (**Next space** / **Previous space**) step through spaces and their open worktree sessions in the sidebar's order. <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⌘</kbd><kbd>↓</kbd> (**Move space up** / **Move space down**) swap the current space with its neighbour in the sidebar, skipping the worktree sessions Tern lists between them. All four are in the palette and rebindable in Tern's keybinds; the README shows how to put Next/Previous on <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↑</kbd>/<kbd>↓</kbd>, which Tern uses for resizing splits by default.
- **Mission control (in progress).** Overseer runs `server/` (Bun) on `127.0.0.1:8095` and restarts it if it stops. omp agents connected to it track tasks, ask you questions, message each other and run goals: a coordinator in the goal's own background session starts workers, each in its own worktree. Your answers and agents' messages reach the right agent within seconds. **Start proposed goal** in the palette starts a goal until the Mission control block lands.
- **Reloading closes an open folder picker.** Since Tern 0.9.16 processes outlive a plugin reload, so New space's picker would have stayed up with nowhere to send the folder.
- **Requires Tern 0.9.16 or later** (the `unload` event; tested with 0.9.18). Overseer also uses the `agent_state`, `budget`, `cwd` and `session_ended` events, and relies on Tern's time budgets: only a plugin's own Lua counts toward the 50 ms, and a hook that runs over is paused for a few seconds rather than switched off until a reload.

### Removed

- **Projects.** Add project and the saved `projects` list are gone; a repository's base branch override now lives in `repo-base`. The old `projects` value is left in storage, unread.
- **Tab rows** under each worktree, the directory subtitle, the Primary badge and the Open hint, and the ⓘ button that opened this README.
- **Ice Box.** The menu entries, the 🧊 header toggle and the `icebox`/`show-icebox` values (left in storage, unread).
- **Linear integration.** Ticket links on worktree rows, **Set Linear workspace** in a project's menu, the `linear auth whoami` lookup, and the ticket link in Visualize PR outlines are gone. So is Carly's `ticket_worktree` (create `feature/<ticket>` and start omp on the ticket) and the project list Overseer gave Carly for it, which was one of the hooks that ran past Tern's 4 ms limit.

### Fixed

- **Sessions of worktrees deleted outside Overseer close themselves.** A worktree removed by `wt merge`, `wt remove` or an agent left its session open, cut off from its repository in Spaces. Once the folder is gone, Overseer now closes that session, unless an agent is still running in it. A repository's primary checkout is never closed this way; each close is written to the operation log.
- **Agents that finish out of sight wait for you.** Tern reports an agent whose turn has ended as idle, so Agents showed it idle straight away. An agent whose turn ends while you're on another tab now shows as waiting until you look at its tab. Agent states also resync from Tern every tick, so a state change Tern sent while Overseer's event hook was paused no longer leaves a row stuck.
- **Creations and deletions no longer get stuck if the tick stops** (from upstream 2.3.1). The 750 ms tick, the only thing that finishes jobs, queued its next run at its end, so a tick cut short ended the chain silently. It now queues first, and a watchdog (every event, plus a `/bin/sleep` process clock outside the timer hook) restarts it when it's over 5 s late. While timers can't run, the process clock finishes due jobs itself. A finished job also comes off the books before its receipt is deleted, so a callback cut short can't repeat or misreport one.
- **`fallow audit` snapshots are ignored** (from upstream). The temporary worktree it registers while checking out its base no longer flashes up as a worktree row.
- **Agents started without a shell are listed.** An agent block whose agent was launched directly (no shell, so no running command line) was dropped from Agents; a block now counts while its program or running command is an agent CLI, so blocks whose agent exited back to a shell still drop out. An agent in a worktree's space goes by the name its row shows (the branch), not the folder.
- **Submitted forms no longer hang until a reload.** The 750 ms tick did form checks, job checks and panel placement in one timer callback; when it ran past Tern's 50 ms budget, Tern switched off every Overseer timer, so New worktree and other forms were never picked up. Each step now runs in a timer callback of its own, and on Tern 0.9.6 an overrun only pauses timers briefly.
- **Projects with no commits yet load.** A freshly initialised repository made Worktrunk report no working-tree status, and Overseer showed "could not determine working-tree status" instead of listing it. Its checkout now shows as clean.
- **Ahead/behind counts are back in worktree tooltips** (from upstream 2.3.3). Worktrunk renamed `main`/`remote` to `default_branch`/`upstream` (already the case in wt 0.80), so tooltips lost them. Both names are read now.
- **Agent states resync every 30 s instead of every tick** (from upstream 2.4.3). The 750 ms tick called `cx.agents:list()` (7–20 ms) to catch events a paused hook missed, enough on its own to push a callback past Tern's budget. `agent_state` events still update at once.
- **The panel keeps its width in tabs with nested splits** (from upstream 2.4.2). It's measured however deeply the tab's splits nest it, instead of only as the tab's whole left side, so it no longer arrives at the wrong width and forgets your resize.
- **A worktree Worktrunk can't read yet no longer hides its whole project.** While a worktree is being created, `wt list` can leave out its working-tree status, and the project showed only "could not determine working-tree status". That worktree now shows normally with its changes unknown until the next refresh, and Delete reads its changes straight from Git before it goes ahead.
- **Agent badges follow Tern's agent events instead of polling.** Every Projects draw called `cx.agents:list()`, which reads each agent's last message: 7–45 ms when cold, slower as agent sessions grow, and the most common cause of Overseer's timeouts. Working and waiting now come from Tern's `agent_state` event, read once from the list when Overseer loads, so a waiting agent shows as soon as it asks.
- **Switching tabs no longer risks disabling the panel.** Focus, tab and pane events moved the panel and redrew it inside the event itself, where a layout rebuild plus a draw could pass Tern's 50 ms budget and switch that event off. Both now run in timer callbacks of their own, and a burst of events shares one move. Each draw also reads the session's tabs and panes once instead of twice.
- **Closing a form no longer leaves it in storage.** Closing a New worktree (or other) form with ⌘W or by closing its tab, rather than Back or Submit, left its request and any submitted answer in Overseer's kv store forever. They're now removed when the window closes the pane. A form pane closed some other way, such as `tern close`, isn't reported to plugins and still leaves them.
- **The Projects panel is full height in split tabs.** Switching to a tab split top-and-bottom put the panel beside only the top half. It's now the tab's whole left column, with the tab's other panes rebuilt to its right in the same splits and ratios.

## 2.0.0 (2026-10-09)

The Projects panel is now one panel per window that follows you, instead of one panel per worktree session.

### Changed

- **The panel follows you.** It sits on the left of whichever tab you're looking at, in any session, and comes along when you switch tabs, open a tab or open a worktree. Before, each worktree session had its own panel beside its first terminal, and a new tab started without one.
- **Your width travels with it.** Drag the panel's edge once; every tab uses that width, and it's remembered across restarts. It starts at 30% of the tab.
- **Forms follow too.** New worktree, Rename, Change base branch and Set Linear workspace still open in the panel's place, and now move with it.
- **The shortcut shows or hides.** <kbd>⌘</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>P</kbd> shows and focuses the panel, or hides it when it already has focus. The command is now **Show or hide Projects**. A hidden panel stays hidden in new tabs until you show it again.
- **Opening a worktree no longer opens a panel in its session.** The one panel moves there instead.
- **Closing the last terminal in a tab** closes the tab as Tern normally does; the panel moves to the tab shown next.
- **Close session** (from Overseer) moves the panel out of the session first. If Tern closes the session holding the panel, Overseer reopens the panel in the next tab you see, unless you had closed it yourself.

### Upgrading

Nothing to do. The first time 2.0 runs, it keeps one of the panels you already had open and closes the others.

### Trade-offs

Tern plugins can't add a window-level sidebar, so the panel is a regular pane that moves between tabs. Each switch briefly animates, and resizes the terminals in the tab you leave and the tab you arrive in. In a tab split top-and-bottom, the panel sits beside the top half.

## 1.10.2 (2026-10-08)

- Slightly smaller type across the panel and forms, a smaller **Projects** heading, and no divider under the header.

## 1.10.1 (2026-10-08)

- First public release: projects and Worktrunk worktrees with a Tern session per worktree, agent activity, pull request and Linear ticket badges, background creation and deletion, Ice Box, ticket worktrees from Carly, and Visualize PR.
- Ticket links use Linear's official logo mark.
