local get_runtime, control, control_host, control_client, features, transport, camera_hud, bag_lifecycle, bag_preview, equipment_placement, equipment_ecm, dart_prediction, ownership_debug, peers, peer_delivery =
	...
local session = {}

local function clear_local_effects()
	ownership_debug:reset()
	dart_prediction:clear()
end

local function reset_features(current, preserve_drop_ordinals)
	bag_lifecycle:reset(preserve_drop_ordinals)
	bag_preview:reset()
	equipment_placement:reset(current)
	equipment_ecm:reset()
end

function session.receive(sender, message, body)
	get_runtime():refresh_session()
	local prefix = type(body) == "string" and body:sub(1, 2)
	if message == control.CHANNEL then
		return (prefix == "d:" and features.receive or prefix == "r:" and peers.receive or control_client.receive)(
			sender,
			body
		)
	elseif message == control.ACK then
		return (
			prefix == "d:" and features.receive_ack
			or prefix == "r:" and peers.receive_ack
			or control_host.receive_ack
		)(sender, body)
	end
	return transport:receive_lua(sender, message, body)
end

function session.announce()
	if not Network:is_server() then
		get_runtime():send_hello()
	end
end

function session.cleanup_for_toggle(current)
	clear_local_effects()
	reset_features(current, true)

	peers.reset()
	peer_delivery:reset()
end

function session.on_detection_session_change()
	clear_local_effects()
	control.reset()
	control_host.reset()
	control_client.reset()
	peers.reset()
	peer_delivery:reset()
end

function session.init(current)
	bag_lifecycle:reset()
	bag_preview:reset()
	get_runtime():reset_session(current)
	equipment_placement:reset(current)
	equipment_ecm:reset()
end

function session.peer_added()
	bag_lifecycle:peer_added()
end

function session.peer_synced()
	local runtime = get_runtime()
	runtime:refresh_session()
	if runtime.enabled == false then
		return
	end
	runtime:sync_players()
	if not Network:is_server() then
		runtime:send_hello()
	end
end

function session.update(now)
	local runtime = get_runtime()
	runtime:refresh_session()
	if control.latch_loud() then
		clear_local_effects()
		camera_hud:reset()
		features.reset()
	end
	local loud = control.is_loud_latched()
	if not loud then
		ownership_debug:update(now)
		dart_prediction:update(TimerManager:game():time())
	elseif Network:is_server() then
		control_host.set_enabled(false)
	else
		control_client.update_loud()
	end
	features.update(now)
	peers.update(now)
	transport:update(now, features.switch_ready)
	peer_delivery:update(now)
	if Network:is_server() and (loud or control_host.has_pending()) then
		control_host.update(now)
	end
	if runtime.enabled == false then
		return
	end
	runtime:update_network(now)
	if runtime:is_active() then
		runtime:sync_players()
	end
	bag_lifecycle:retry_pending_held()
	bag_preview:update(now)
	equipment_placement:update(now)
	equipment_ecm:update(now)
end

function session.level_loaded(current)
	if control.is_loud_latched() then
		session.init(current)
	end
end

function session.peer_lost(peer_id)
	local runtime = get_runtime()
	runtime:refresh_session()
	control_host.peer_lost(peer_id)
	transport:forget(peer_id)
	peers.peer_lost(peer_id)
	peer_delivery:peer_lost(peer_id)
	bag_lifecycle:peer_lost(peer_id)
	if peer_id == runtime.host_peer_id then
		dart_prediction:clear()
		bag_preview:reset()
	end
	equipment_placement:peer_lost(peer_id)
	equipment_ecm:peer_lost(peer_id)
	runtime:peer_lost(peer_id)
end

function session.destroy()
	reset_features(nil)
	get_runtime():reset_session(nil)
end

return session
