-- Unlock your SSH security key: a small terminal floating in the corner of
-- the current tab runs `git fetch` in a repository with an SSH remote, so
-- the key asks for its touch or PIN. On success it closes itself after a
-- moment; on failure it stays until you press Enter.
local M = {}

-- The shell command the floating terminal runs: in your login shell, so git
-- uses the ssh (and agent) your terminals use. macOS's own /usr/bin/ssh can't
-- use a security key, and Tern's PATH may not put Homebrew's first.
local SCRIPT = table.concat({
	'printf "Unlocking your SSH key: git fetch in %s\\n\\n" "$PWD"',
	'if git fetch; then printf "\\n\\033[32mUnlocked.\\033[0m\\n"; sleep 1.5',
	'else printf "\\n\\033[31mgit fetch failed.\\033[0m Press Enter to close."; read -r _; fi',
}, "; ")
M.COMMAND = "exec \"${SHELL:-/bin/zsh}\" -ilc '" .. SCRIPT .. "'"

-- Whether `dir` is a Git checkout whose origin is reached over SSH. done(ok).
local function sshRepo(dir, done)
	tern.process.run({ "/usr/bin/git", "-C", dir, "remote", "get-url", "origin" }, { timeout_ms = 5000 }, function(r)
		local url = r.status == 0 and r.stdout or ""
		done(string.match(url, "^git@") ~= nil or string.match(url, "^ssh://") ~= nil)
	end)
end

-- Opens the terminal over the focused pane. `candidates`: folders to try in
-- order (the focused pane's, then known repositories); the first SSH checkout wins.
function M.open(cx, candidates)
	local over = cx.session:focused()
	local function try(i)
		local dir = candidates[i]
		if not dir then
			cx:toast("warn", "No repository to fetch", "Open a repository with an SSH remote in a space first.")
			return
		end
		sshRepo(dir, function(ok)
			if not ok then try(i + 1); return end
			tern.timer(0, function(nextCx)
				if not nextCx then return end
				local pane = nextCx.layout:split(over, "right", { cwd = dir, command = M.COMMAND })
				if not pane then return end
				nextCx.layout:float(pane, over, "br", { focus = true, size = { 0.45, 0.35 } })
			end)
		end)
	end
	try(1)
end

return M
