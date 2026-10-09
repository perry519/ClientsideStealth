local world_target, get_runtime = ...
local M = {}
local actions = {}

local function next_action_key(unit, peer_id)
	local key = unit:id() .. ":" .. peer_id
	actions[key] = (actions[key] or 0) + 1
	return "hostage:" .. key .. ":" .. actions[key]
end

local function accept(unit, peer_id, cause, source_unit)
	local id = unit:id()
	if id == -1 then
		return nil
	end
	if not peer_id then
		return world_target.register("hostage", id, unit, peer_id, "civ_enemy_cbt")
	end
	local runtime = get_runtime()
	local config = world_target.config(unit, "civ_enemy_cbt")
	local session = managers.network and managers.network:session()
	local owner = session and session.peer and session:peer(peer_id)
	local spec = {
		kind = "hostage",
		unit = unit,
		canonical_unit = unit,
		id = id,
		owner_peer_id = peer_id,
		cause = cause,
		source_unit = source_unit or owner and owner:unit(),
		native_key = next_action_key(unit, peer_id),
		config = config,
	}
	if Network:is_server() then
		local target = world_target.register("hostage", id, unit, peer_id, "civ_enemy_cbt")
		runtime:confirm_prediction(spec)
		return target
	end
	local local_peer = session and session.local_peer and session:local_peer()
	if config and local_peer and local_peer:id() == peer_id then
		spec.attention = world_target.prediction_attention(unit, config)
		local target = runtime:predict_target(spec)
		if target then
			return target
		end
	end
	return world_target.register("hostage", id, unit, nil, "civ_enemy_cbt")
end

function M.tied(unit, sender_peer_id, aggressor)
	local peer_id = sender_peer_id
	if peer_id == nil then
		peer_id = world_target.peer_id(aggressor)
	elseif peer_id == false then
		peer_id = nil
	end
	if unit:id() ~= -1 then
		accept(unit, peer_id, "hostage_tie", aggressor)
	end
end

function M.commanded(unit, instigator, command)
	if command == "release" then
		world_target.unregister_unit(unit)
		return
	end
	local peer_id = world_target.peer_id(instigator)
	if unit:id() ~= -1 and peer_id then
		accept(unit, peer_id, command == "move" and "hostage_follow" or "hostage_stop", instigator)
	end
end

function M.released(unit)
	world_target.unregister_unit(unit)
end

return M
