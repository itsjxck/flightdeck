-- Follows the server's change stream (GET /api/events, server/src/events.ts)
-- and calls onChange when something changed, so its caller fetches at once
-- instead of polling often. Used by the window (mission.luau) and by Mission
-- control (ui/block.luau), each in its own VM. Reconnects RETRY_MS after the
-- stream ends (server restart, timeout); `alive()` returning false stops it.
local M = {}

local RETRY_MS = 3000
-- A request's whole lifetime is bounded by its timeout; reconnect before then.
local STREAM_MS = 10 * 60 * 1000

-- `url`: the server's base URL; `token()`: the bearer token, or nil while there's none yet.
function M.follow(url, token, onChange, alive)
	local function connect()
		if alive and not alive() then return end
		local t = token()
		if not t then tern.timer(RETRY_MS, connect); return end
		local ok = pcall(tern.fetch, url .. "/api/events", {
			timeout_ms = STREAM_MS,
			headers = { Authorization = "Bearer " .. t },
			stream = function(_chunk, head, cx)
				if alive and not alive() then return false end
				if head.status == 200 then onChange(cx) end
				return nil
			end,
		}, function()
			tern.timer(RETRY_MS, connect)
		end)
		if not ok then tern.timer(RETRY_MS, connect) end
	end
	connect()
end

return M
