local get_runtime, log_event = ...
local control = {}
control.CHANNEL = "cst_runtime_v1"
control.ACK = "cst_runtime_v1_ack"
local pause_blockers = {}
local features

function control.use_features(owner)
	features = owner
end

function control.send(peer_id, channel, body)
	LuaNetworking:SendToPeer(peer_id, channel, body)
end

function control.reset()
	control.preparing = nil
	control.loud = nil
end

function control.status(text_id)
	log_event("runtime_toggle", { "status", text_id })
	local hud = managers and managers.hud
	if hud and hud.show_hint then
		hud:show_hint({ text = managers.localization:text(text_id) })
	end
end

function control.add_pause_blocker(owner, group)
	pause_blockers[#pause_blockers + 1] = { owner = owner, group = group }
end

function control.busy_for(groups, local_only)
	for _, blocker in ipairs(pause_blockers) do
		if (not groups or groups[blocker.group]) and blocker.owner:busy_for_pause(local_only) then
			return true
		end
	end
	return false
end

function control.busy_for_pause(local_only)
	return control.busy_for(nil, local_only)
end

function control.set_preparing(value)
	control.preparing = value or nil
end

function control.is_preparing()
	return control.preparing == true
end

function control.is_loud_latched()
	return control.loud == true
end

function control.is_loud()
	if control.loud then
		return true
	end
	local state = managers and managers.groupai and managers.groupai:state()
	return state ~= nil
		and game_state_machine ~= nil
		and GameStateFilters ~= nil
		and game_state_machine:verify_game_state(GameStateFilters.any_ingame_playing)
		and not state:whisper_mode()
end

function control.latch_loud()
	if control.loud or not control.is_loud() then
		return false
	end
	control.loud = true
	return true
end

function control.is_running()
	return get_runtime().enabled ~= false and not control.preparing and not control.is_loud()
end

function control.allows_new_work(feature, peer_id)
	local runtime = get_runtime()
	local enabled
	if peer_id and peer_id ~= runtime.local_peer_id then
		enabled = features.allows_peer(peer_id, feature)
	else
		enabled = features.allows(feature)
	end
	return enabled and control.is_running()
end

return control
