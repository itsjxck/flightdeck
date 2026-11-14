-- Mission control's Overseer side: what Overseer does for overseer-server.
-- window.luau calls tick() from its tick; the work lives in mission/:
--
--   client.luau      server address, token, JSON calls
--   server.luau      keeps the server running
--   deliveries.luau  your answers and agents' messages, to the right pane
--
-- Every server call is a tern.fetch with a callback of its own, so no single
-- callback nears Tern's 50 ms budget.
local client = require("./mission/client")
local server = require("./mission/server")
local deliveries = require("./mission/deliveries")

local M = {}

local POLL_MS = 2000

M.api = client.api
-- Which pane each omp session runs in, from the last poll ({ [session] = pane }).
M.sessionPanes = {}

local polling, lastPoll = false, -POLL_MS

-- Called from Overseer's tick. `panes`: every live terminal and agent pane id (strings).
-- `hooks`: what the window knows (see missionHooks in window.luau).
function M.tick(_cx, panes, _hooks)
	server.watch()
	if not server.healthy() or polling or tern.now() - lastPoll < POLL_MS then return end
	polling, lastPoll = true, tern.now()
	-- Each step runs in the callback of the one before; `polling` stays set until the last.
	client.api("POST", "/api/panes", { panes = panes }, function(map, err)
		if err or type(map) ~= "table" then polling = false; return end
		M.sessionPanes = map
		deliveries.run(map, function() polling = false end)
	end)
end

return M
