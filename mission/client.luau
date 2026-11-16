-- Talking to flightdeck-server: its address, the access token it writes into
-- Flightdeck's plugin data directory, and one JSON call helper. Also where the
-- `tern` CLI lives and a warn-once logger, shared by the mission modules.
local M = {}

-- FLIGHTDECK_PORT in Tern's environment moves the server (a second instance, a demo).
M.PORT = tonumber(tern.getenv("FLIGHTDECK_PORT") or "") or 8095
M.BASE = "http://127.0.0.1:" .. M.PORT
M.TERN = tern.getenv("TERN_EXE") or "/Applications/Tern.app/Contents/MacOS/tern"

local warned = {}
-- Logs `message` to Tern's log once per `key`, so a failure repeating every poll doesn't flood it.
function M.warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	tern.log.warn("Flightdeck Mission control: " .. message)
end

local token
local function readToken()
	if token then return token end
	local ok, text = pcall(tern.fs.read, tern.plugin.data .. "/token", 256)
	if ok then token = string.match(text, "^%s*(.-)%s*$") end
	return token
end

M.token = readToken

-- Calls the server's JSON API. fn(body, err, cx); err is a readable reason.
function M.api(method, path, body, fn)
	local t = readToken()
	if not t then fn(nil, "the server hasn't created its token yet", nil); return end
	tern.fetch(M.BASE .. path, {
		method = method, timeout_ms = 10000,
		headers = { Authorization = "Bearer " .. t, ["Content-Type"] = "application/json" },
		body = if body ~= nil then tern.json.encode(body) else nil,
	}, function(result, cx)
		if result.error then fn(nil, result.error, cx); return end
		local ok, decoded = pcall(tern.json.decode, result.body)
		if result.status ~= 200 then
			local reason = if ok and type(decoded) == "table" and decoded.error then decoded.error else "HTTP " .. tostring(result.status)
			fn(nil, reason, cx)
			return
		end
		fn(if ok then decoded else nil, nil, cx)
	end)
end

-- Fire-and-forget POST; failures are only logged.
function M.post(path, body)
	M.api("POST", path, body, function(_, err)
		if err then M.warnOnce("post " .. path .. err, "POST " .. path .. ": " .. err) end
	end)
end

return M
