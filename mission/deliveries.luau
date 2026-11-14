-- Hands the server's queued deliveries (your answers, agents' messages) to
-- the agents they're for. Everything pending for one pane goes as one
-- prompt; each is marked delivered only after the prompt was accepted, so a
-- failed send is retried on the next poll. The 2-minute spacing between
-- agent-to-agent messages is the server's (store.ts pendingDeliveries).
local client = require("./client")
local oplog = require("../oplog")

local M = {}

-- Groups deliveries by the pane running their session, oldest first; drops
-- ones whose session runs in no pane right now (they stay queued).
-- `deliveries`: { id, session, text }[]; `sessionPanes`: { [session] = pane }.
function M.bundle(deliveries, sessionPanes)
	local byPane, order = {}, {}
	for _, d in deliveries do
		local pane = d.session and sessionPanes[d.session]
		if pane then
			if not byPane[pane] then byPane[pane] = {}; table.insert(order, pane) end
			table.insert(byPane[pane], d)
		end
	end
	local out = {}
	for _, pane in order do
		local texts, ids = {}, {}
		for _, d in byPane[pane] do table.insert(texts, d.text); table.insert(ids, d.id) end
		table.insert(out, { pane = pane, text = table.concat(texts, "\n\n---\n\n"), ids = ids })
	end
	return out
end

do
	local b = M.bundle({ { id = 1, session = "a", text = "x" }, { id = 2, session = "b", text = "y" },
		{ id = 3, session = "a", text = "z" }, { id = 4, session = "gone", text = "w" } }, { a = "10", b = "20" })
	assert(#b == 2 and b[1].pane == "10" and b[1].text == "x\n\n---\n\nz" and b[1].ids[2] == 3 and b[2].pane == "20",
		"deliveries.bundle self-check")
end

-- One delivery pass. done() runs when it's finished, whatever happened.
function M.run(sessionPanes, done)
	client.api("GET", "/api/deliveries", nil, function(list, err, cx)
		if err or not cx or type(list) ~= "table" then done(); return end
		for _, bundle in M.bundle(list, sessionPanes) do
			local ok, askErr = pcall(function() cx.agents:ask(tonumber(bundle.pane), bundle.text) end)
			if ok then
				for _, id in bundle.ids do client.post("/api/deliveries/" .. tostring(id) .. "/done", {}) end
				oplog.write("info", { op = "mission", event = "delivered",
					detail = "pane " .. bundle.pane .. " (" .. tostring(#bundle.ids) .. ")" })
			else
				client.warnOnce("ask " .. bundle.pane .. tostring(askErr), "couldn't deliver to pane " .. bundle.pane .. ": " .. tostring(askErr))
			end
		end
		done()
	end)
end

return M
