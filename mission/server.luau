-- Keeps overseer-server (server/, Bun) running. Every HEALTH_MS it checks
-- /health; it starts the server when it has never seen it healthy, or after
-- two failed checks in a row. The process outlives plugin reloads (Tern
-- 0.9.16+), so a reload just finds it healthy; a second start while one runs
-- exits on the busy port, harmlessly. Output goes to server.log in the plugin
-- data directory; starts and exits go to ops.log (op "server").
local client = require("./client")
local oplog = require("../oplog")
local wt = require("../worktrunk")

local M = {}

local HEALTH_MS = 5000

local healthy, everHealthy, failures, starting, lastCheck = false, false, 0, false, -HEALTH_MS

local function start()
	-- Bun is looked up like wt is (PATH, Homebrew, ~/.bun/bin): Tern's PATH may not include it.
	local bun = wt.find_executable("bun")
	if not bun then client.warnOnce("bun", "Bun isn't installed; Mission control's server can't start"); return end
	starting = true
	-- Installs dependencies on first run, then replaces the shell with the server.
	local script = 'cd "$1" && { [ -d node_modules ] || "$4" install --frozen-lockfile; } && exec "$4" src/main.ts "$2" >>"$3" 2>&1'
	local argv = { "/bin/sh", "-c", script, "overseer-server",
		tern.plugin.dir .. "/server", tern.plugin.data, tern.plugin.data .. "/server.log", bun }
	local ok, err = pcall(tern.process.run, argv, {}, function(result)
		starting = false
		oplog.write("warn", { op = "server", event = "exited", detail = "status " .. tostring(result.status) })
	end)
	if not ok then
		starting = false
		client.warnOnce("spawn", "couldn't start the server: " .. tostring(err))
		return
	end
	oplog.write("info", { op = "server", event = "started" })
end

-- Whether the last health check passed.
function M.healthy()
	return healthy
end

-- Runs a health check when one is due; call it every tick.
function M.watch()
	if tern.now() - lastCheck < HEALTH_MS then return end
	lastCheck = tern.now()
	tern.fetch(client.BASE .. "/health", { timeout_ms = 3000 }, function(result)
		healthy = result.status == 200
		if healthy then everHealthy, failures = true, 0; return end
		failures += 1
		if not starting and (not everHealthy or failures >= 2) then start() end
	end)
end

return M
