local get_runtime, control = ...
local client = {}
client.seq = -1

function client.reset()
	client.seq = -1
end

function client.has_seen_host_control()
	return client.seq >= 0
end

local function ack(sequence, result)
	control.send(get_runtime().host_peer_id, control.ACK, tostring(sequence) .. ":" .. result)
end

function client.update_loud()
	local runtime = get_runtime()
	if
		runtime.enabled == false
		or control.is_preparing()
		or control.busy_for_pause()
		or runtime:is_peer_capable(runtime.host_peer_id)
		or client.has_seen_host_control()
	then
		return
	end
	runtime:set_enabled(false)
end

function client.receive(sender, body)
	local runtime = get_runtime()
	local session = runtime:session()
	if Network:is_server() or not session or sender ~= runtime.host_peer_id or type(body) ~= "string" or #body > 32 then
		return false
	end
	local sequence, enabled, floor = body:match("^(%d+):([01lp]):(%d+)$")
	local loud = enabled == "l"
	enabled = loud and "0" or enabled
	sequence = sequence and tonumber(sequence)
	floor = floor and tonumber(floor)
	if not sequence or sequence > 1000000000 or not floor or floor > 1000000000 or sequence < client.seq then
		return false
	end
	if enabled == "p" then
		if runtime.enabled == false and sequence == client.seq then
			ack(sequence, "ok")
			return true
		end
		if control.busy_for_pause() then
			if control.is_loud_latched() then
				control.set_preparing(nil)
			end
			ack(sequence, "busy")
			return false
		end
		control.set_preparing(true)
		client.seq = sequence
		runtime:cancel_predictions("pause")
		ack(sequence, "ready")
		return true
	end
	if
		enabled == "0"
		and runtime.enabled ~= false
		and not control.is_preparing()
		and runtime.mode ~= "client_pending"
	then
		return false
	end
	if enabled == "0" and runtime.enabled ~= false and control.busy_for_pause() then
		ack(sequence, "busy")
		return false
	end
	if sequence > client.seq or enabled == "0" and runtime.enabled ~= false then
		client.seq = sequence
		local was_enabled = runtime.enabled ~= false
		if enabled ~= "1" or not control.is_loud() then
			runtime:set_enabled(enabled == "1")
		end
		runtime:reject_snapshots_through(floor)

		if (runtime.enabled ~= false) ~= was_enabled and not loud then
			control.status(was_enabled and "cst_status_disabled_by_host" or "cst_status_enabled_by_host")
		end
	end
	control.set_preparing(nil)
	ack(sequence, "ok")
	return true
end

return client
