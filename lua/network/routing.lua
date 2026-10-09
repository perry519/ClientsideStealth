local get_runtime, bag_lifecycle, camera_hud, Channel, peer_delivery = ...
local PEER = { [Channel.peer] = true, [Channel.peer_relay] = true, [Channel.peer_receipt] = true }

return function(id, channel, record)
	local runtime = get_runtime()
	runtime:refresh_session()
	if runtime.enabled == false and channel ~= Channel.hello then
		return false
	end
	if not runtime.current_session or runtime.mode == "inactive" then
		return false
	end
	if channel == Channel.bag then
		return bag_lifecycle:receive_record(id, record)
	elseif not runtime:authority_matches() then
		return false
	elseif channel == Channel.camera_hud then
		return not runtime:is_host() and camera_hud:receive(id, record)
	elseif PEER[channel] then
		return peer_delivery:receive(id, channel, record)
	end
	return runtime:receive_record(id, channel, record)
end
