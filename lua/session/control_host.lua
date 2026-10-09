local get_runtime, control = ...
local host = {}
host.seq = 0

function host.reset()
	host.seq = 0
	host.pending = nil
	host.peers = nil
	host.phase = nil
	host.loud_off = nil
end

function host.has_pending()
	return host.pending and next(host.pending) ~= nil or false
end

function host.knows_peer(peer_id)
	return host.peers and host.peers[peer_id] == true or false
end

local function send(peer_id, runtime)
	control.send(
		peer_id,
		control.CHANNEL,
		tostring(host.seq)
			.. ":"
			.. (host.phase == "prepare" and "p" or runtime.enabled == false and (host.loud_off and "l" or "0") or "1")
			.. ":"
			.. tostring(runtime.snapshot_seq)
	)
end

local function send_enabled(peer_id)
	local runtime = get_runtime()
	local session = runtime:session()
	if Network:is_server() and session and session:peer(peer_id) then
		send(peer_id, runtime)
		host.pending = host.pending or {}
		host.pending[peer_id] = { retry = 0 }
	end
end

function host.peer_negotiated(peer_id)
	if host.knows_peer(peer_id) then
		return
	end
	host.peers = host.peers or {}
	host.peers[peer_id] = true
	send_enabled(peer_id)
end

function host.set_enabled(enabled)
	local runtime = get_runtime()
	local session = runtime:session()
	if enabled and control.is_loud() then
		return false
	end
	if type(enabled) ~= "boolean" or not session or not Network:is_server() then
		return false
	end
	if not enabled and (runtime.enabled == false or control.is_preparing() or control.busy_for_pause()) then
		return false
	end
	if not enabled then
		host.loud_off = control.is_loud_latched()
	end
	host.peers = host.peers or {}
	for id in pairs(runtime.capable_peers) do
		if id ~= runtime.local_peer_id then
			host.peers[id] = true
		end
	end
	local cancelling = enabled and host.phase == "prepare"
	if not cancelling and not enabled and next(host.peers) then
		control.set_preparing(true)
		host.phase = "prepare"
	elseif not cancelling then
		if not runtime:set_enabled(enabled) then
			return false
		end
		host.phase = enabled and "on" or "off"
	else
		control.set_preparing(nil)
		host.phase = "on"
	end
	host.seq = host.seq + 1
	host.pending = {}
	for id in pairs(host.peers) do
		send_enabled(id)
	end
	if host.phase == "prepare" and not next(host.pending) then
		return host.finish_prepare()
	end
	control.status(
		next(host.pending) and (enabled and "cst_status_resume_requested" or "cst_status_pause_requested")
			or (enabled and "cst_status_enabled_sync_detection" or "cst_status_disabled_ready")
	)
	return true
end

function host.finish_prepare()
	local runtime = get_runtime()
	if host.phase ~= "prepare" or next(host.pending or {}) then
		return false
	end
	if control.busy_for_pause() then
		if control.is_loud_latched() then
			control.set_preparing(nil)
			return false
		end
		host.set_enabled(true)
		control.status("cst_status_pause_cancelled_host_busy")
		return false
	end
	control.set_preparing(nil)
	runtime:set_enabled(false)
	host.phase = "off"
	host.pending = {}
	for id in pairs(host.peers or {}) do
		send_enabled(id)
	end
	control.status(next(host.pending) and "cst_status_pause_committing" or "cst_status_disabled_ready")
	return true
end

function host.update(now)
	local runtime = get_runtime()
	if not Network:is_server() then
		return
	end
	for id, pending in pairs(host.pending or {}) do
		pending.started = pending.started or now
		if now - pending.started >= 10 and not control.is_loud_latched() then
			host.pending[id] = nil
			if host.phase == "prepare" or runtime.enabled == false then
				host.set_enabled(true)
				control.status("cst_status_pause_cancelled_peer_timeout")
				return
			elseif not next(host.pending) then
				control.status("cst_status_resume_unconfirmed_peer_timeout")
			end
		elseif now >= pending.retry then
			local session = runtime:session()
			if not session or not session:peer(id) then
				host.pending[id] = nil
			else
				send(id, runtime)
				pending.retry = now + 1
			end
		end
	end
	if host.phase == "prepare" and not next(host.pending or {}) then
		host.finish_prepare()
	end
end

function host.peer_lost(peer_id)
	if host.pending then
		host.pending[peer_id] = nil
	end
	if host.peers then
		host.peers[peer_id] = nil
	end
	if host.phase == "prepare" then
		host.finish_prepare()
	elseif get_runtime().enabled == false and host.pending and not next(host.pending) then
		control.status("cst_status_disabled_ready")
	end
end

function host.on_hello(peer_id)
	if control.is_loud_latched() then
		host.peers = host.peers or {}
		host.peers[peer_id] = true
		if host.phase == "prepare" or get_runtime().enabled == false then
			send_enabled(peer_id)
		end
		return false
	end
	if host.phase == "prepare" then
		host.set_enabled(true)
		control.status("cst_status_pause_cancelled_peer_joined")
	end
	if get_runtime().enabled == false then
		host.peers = host.peers or {}
		host.peers[peer_id] = true
		send_enabled(peer_id)
		control.status("cst_status_pause_sync_peer")
		return false
	end
	return true
end

function host.receive_ack(sender, body)
	local runtime = get_runtime()
	local session = runtime:session()
	if
		not Network:is_server()
		or not session
		or not session:peer(sender)
		or type(body) ~= "string"
		or not host.pending
		or not host.pending[sender]
	then
		return false
	end
	if body == tostring(host.seq) .. ":busy" and host.phase == "prepare" then
		if control.is_loud_latched() then
			return true
		end
		host.set_enabled(true)
		control.status("cst_status_pause_cancelled_peer_busy")
		return true
	end
	local expected = host.phase == "prepare" and ":ready" or ":ok"
	if body ~= tostring(host.seq) .. expected then
		return false
	end
	host.pending[sender] = nil
	if host.phase == "prepare" then
		return host.finish_prepare()
	end
	if not next(host.pending) then
		control.status(runtime.enabled == false and "cst_status_disabled_ready" or "cst_status_enabled_sync_detection")
	end
	return true
end

return host
