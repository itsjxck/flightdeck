-- Mission control's Overseer side: what Overseer does for overseer-server.
-- window.luau calls tick() from its tick; the work lives in mission/:
--
--   client.luau      server address, token, JSON calls
--   server.luau      keeps the server running
--
-- Every server call is a tern.fetch with a callback of its own, so no single
-- callback nears Tern's 50 ms budget.
local client = require("./mission/client")
local server = require("./mission/server")

local M = {}

M.api = client.api

-- Called from Overseer's tick. `panes`: every live terminal and agent pane id (strings).
-- `hooks`: what the window knows (see missionHooks in window.luau).
function M.tick(_cx, _panes, _hooks)
	server.watch()
end

return M
