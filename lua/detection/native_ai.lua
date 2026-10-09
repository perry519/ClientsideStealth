local get_runtime, adapters, camera_hud, restoring_call = ...
local M = {}

local function not_cuffed()
	return false
end

function M.camera_jamming_changed()
	if Network:is_server() then
		get_runtime():mark_state_dirty()
	end
end

function M.filter_attention(objects)
	return get_runtime():filter_attention(objects, true)
end

function M.filter_indexed_attention(objects)
	local filtered = get_runtime():filter_attention(objects)
	if filtered == objects then
		return objects
	end
	local dense = {}
	for index = 1, #objects do
		if filtered[index] then
			dense[#dense + 1] = filtered[index]
		end
	end
	for index, attention in pairs(filtered) do
		if type(index) ~= "number" or index < 1 or index > #objects then
			dense[#dense + 1] = attention
		end
	end
	return dense
end

function M.suppress_suspicion(state, suspect, observer, status)
	local npc = adapters.npc
	if
		npc
		and npc.suppress_surrender_suspicion
		and npc.suppress_surrender_suspicion(observer, suspect, status, state)
	then
		return true
	end
	local camera = adapters.camera
	if camera and camera.defer_corpse_hud and camera.defer_corpse_hud(suspect, observer, status) then
		return true
	end
	if Network:is_server() or suspect ~= nil then
		return false
	end
	if status ~= false and adapters.player and adapters.player.host_suspicion then
		adapters.player.host_suspicion(state, observer)
	end
	local hud = state._suspicion_hud_data
	if status == true or type(status) == "string" then
		local current = hud and hud[observer:key()]
		if current and adapters.guard and adapters.guard.host_owns_alert then
			adapters.guard.host_owns_alert(current)
		end
		return false
	end
	if status ~= false or not alive(observer) then
		return false
	end
	local current = hud and hud[observer:key()]
	if not current or current.alerted then
		return false
	end
	local snapshot = get_runtime():local_detection_snapshot()
	local owned = snapshot and snapshot.observers[observer:key()]
	return owned ~= nil and owned.unit == observer and type(owned.uncover_progress) == "number"
end

function M.suspicion_routing(state, suspect, observer, status)
	if not Network:is_server() or not suspect or not alive(observer) then
		return nil
	end
	local runtime = get_runtime()
	local current = state._suspicion_hud_data and state._suspicion_hud_data[observer:key()]
	if not runtime:is_active() or current and current.alerted then
		return nil
	end
	local responsible = camera_hud:host_progress(suspect, observer, status)
	local owner
	if not responsible and not camera_hud:is_camera(observer) then
		owner = runtime:delegated_hud_owner(suspect, observer)
	end
	if owner or responsible and next(responsible) then
		return owner, responsible
	end
	return nil
end

function M.civilian_priority(data, best, reaction)
	local runtime = get_runtime()
	if not (data.cool and runtime.core.is_host and runtime:is_active()) then
		return best, reaction
	end
	for _, attention in pairs(data.detected_attention_objects) do
		local delegated = attention.identified and not attention.pause_expire_t and attention.settings.reaction
		local target = delegated
			and delegated >= AIAttentionObject.REACT_SCARED
			and (not reaction or delegated > reaction)
			and runtime:target_for_unit(attention.unit)
		if target and not runtime:owns_detection(target.kind, target.id, runtime.local_peer_id) then
			best, reaction = attention, delegated
		end
	end
	return best, reaction
end

function M.scopes_guard(data)
	local runtime = get_runtime()
	return runtime:is_active() and not (runtime.core.is_host and data.cool == false) and data.unit:id() ~= -1
end

function M.detect_guard(data, native, ...)
	local runtime = get_runtime()
	local id = data.unit:id()
	local removed = {}
	local peer_id = runtime.local_peer_id

	for key, attention in pairs(data.detected_attention_objects or {}) do
		local target = runtime:target_for_unit(attention.unit)

		if
			target and not runtime:owns_detection(target.kind, target.id, peer_id)
			or not target and peer_id ~= runtime.host_peer_id
		then
			removed[key] = attention
			data.detected_attention_objects[key] = nil
		end
	end

	local indexed = data.detected_attention_objects_i
	if indexed then
		for index = indexed[0], 1, -1 do
			if removed[indexed[index].u_key] then
				indexed[index] = indexed[indexed[0]]
				indexed[indexed[0]] = nil
				indexed[0] = indexed[0] - 1
			end
		end
	end

	local groupai = data._cst_client_detection and managers.groupai and managers.groupai:state()
	local original_importance = groupai and rawget(groupai, "set_importance_weight")
	local player_movement, original_is_cuffed
	if data._cst_client_detection and not runtime.core.is_host then
		local player = managers.player and managers.player:player_unit()
		local target = alive(player) and runtime:target_for_unit(player)
		if
			target
			and target.kind == "player"
			and target.id == peer_id
			and runtime:owns_detection("player", peer_id, peer_id)
		then
			player_movement = player:movement()
			original_is_cuffed = rawget(player_movement, "is_cuffed")

			player_movement.is_cuffed = not_cuffed
		end
	end

	if groupai then
		groupai.set_importance_weight = function(_, _, report)
			local guard = adapters.guard
			if guard and guard.set_importance_weight then
				guard.set_importance_weight(id, report)
			end
		end
	end

	local delay = restoring_call(function()
		if player_movement then
			player_movement.is_cuffed = original_is_cuffed
		end
		if groupai then
			groupai.set_importance_weight = original_importance
		end
		for key, attention in pairs(removed) do
			data.detected_attention_objects[key] = attention
		end
	end, runtime.with_scope, runtime, "guard", id, native, data, ...)

	if runtime.core.is_host then
		for _, attention in pairs(removed) do
			if attention.identified then
				delay = math.min(delay, attention.settings.verification_interval)
			end
		end
	end

	return delay
end

return M
