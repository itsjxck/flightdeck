-- Keeps flightdeck-server (server/, Bun) running. Every HEALTH_MS it checks
-- /health; it starts the server when it has never seen it healthy, or after
-- two failed checks in a row, and at once when the server it started exits.
-- It runs as a `tern.process.spawn` child, which outlives plugin reloads: a
-- reload finds it healthy, and if it ends later the new VM hears it through
-- `process_exit` (its pid is kept in kv `server-pid`). A second start while
-- one runs exits on the busy port, harmlessly. The server writes server.log
-- in the plugin data directory itself; starts and exits go to ops.log.
local client = require("./client")
local oplog = require("../oplog")
local wt = require("../worktrunk")

local M = {}

local HEALTH_MS = 5000

local healthy, everHealthy, failures, starting, lastCheck = false, false, 0, false, -HEALTH_MS

local start

-- The server ended: log it and start it again on the next check.
local function exited(status)
	starting, healthy, everHealthy = false, false, false
	tern.kv.set("server-pid", nil)
	oplog.write("warn", { op = "server", event = "exited", detail = "status " .. tostring(status) })
end

local function spawnServer(bun)
	local dir = tern.plugin.dir .. "/server"
	local ok, child = pcall(tern.process.spawn, { bun, "src/main.ts", tern.plugin.data }, {
		cwd = dir,
		env = { FLIGHTDECK_LOG = tern.plugin.data .. "/server.log" },
		-- It logs to FLIGHTDECK_LOG; anything else on stdout is dropped. stderr's tail comes with `exit`.
		stdout = function() end,
		exit = function(result) exited(result.status) end,
	})
	if not ok then
		starting = false
		client.warnOnce("spawn", "couldn't start the server: " .. tostring(child))
		return
	end
	tern.kv.set("server-pid", child.pid)
	oplog.write("info", { op = "server", event = "started", detail = "pid " .. tostring(child.pid) })
end

start = function()
	-- Bun is looked up like wt is (PATH, Homebrew, ~/.bun/bin): Tern's PATH may not include it.
	local bun = wt.find_executable("bun")
	if not bun then client.warnOnce("bun", "Bun isn't installed; Mission control's server can't start"); return end
	starting = true
	local dir = tern.plugin.dir .. "/server"
	if tern.fs.exists(dir .. "/node_modules") then spawnServer(bun); return end
	-- First run: install its dependencies.
	tern.process.run({ bun, "install", "--frozen-lockfile" }, { cwd = dir, timeout_ms = 300000 }, function(r)
		if r.status ~= 0 then
			starting = false
			client.warnOnce("install", "couldn't install the server's dependencies: " .. (r.stderr or ""):sub(1, 300))
			return
		end
		spawnServer(bun)
	end)
end

-- A server started before a reload ended: start a new one now.
tern.on("process_exit", function(ev)
	if ev.pid == tern.kv.get("server-pid") then exited(ev.status) end
end)

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
