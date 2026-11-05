# Changelog

## Unreleased

### Added

- **Remove project** in a project's right-click menu takes it off the list. The repository, its worktrees and open sessions are left alone; Overseer forgets the project's display names, Ice Box entries and session links. It's refused while a worktree is being created or deleted there.

### Changed

- **Requires Tern 0.9.6 or later.** Overseer uses its `agent_state` and `budget` events, and relies on its time budgets: only a plugin's own Lua counts toward the 50 ms, and a hook that runs over is paused for a few seconds rather than switched off until a reload.

### Removed

- **Linear integration.** Ticket links on worktree rows, **Set Linear workspace** in a project's menu, the `linear auth whoami` lookup, and the ticket link in Visualize PR outlines are gone. So is Carly's `ticket_worktree` (create `feature/<ticket>` and start omp on the ticket) and the project list Overseer gave Carly for it, which was one of the hooks that ran past Tern's 4 ms limit. A `linear` value saved on a project is ignored.

### Fixed

- **Submitted forms no longer hang until a reload.** The 750 ms tick did form checks, job checks and panel placement in one timer callback; when it ran past Tern's 50 ms budget, Tern switched off every Overseer timer, so New worktree and other forms were never picked up. Each step now runs in a timer callback of its own, and on Tern 0.9.6 an overrun only pauses timers briefly.
- **Projects with no commits yet load.** A freshly initialised repository made Worktrunk report no working-tree status, and Overseer showed "could not determine working-tree status" instead of listing it. Its checkout now shows as clean.
- **A worktree Worktrunk can't read yet no longer hides its whole project.** While a worktree is being created, `wt list` can leave out its working-tree status, and the project showed only "could not determine working-tree status". That worktree now shows normally with its changes unknown until the next refresh, and Delete waits until its changes can be checked.
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
