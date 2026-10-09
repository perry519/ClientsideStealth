local world_target, get_runtime, adapters = ...
local M = {}

local candidates = {}
local deaths = {}

function M.damage_received(unit, damage_info)
	if damage_info.result.type ~= "death" then
		return
	end
	local bag = adapters.bag
	if bag and bag.corpse_died then
		bag.corpse_died(unit, managers.enemy:get_corpse_unit_data_from_key(unit:key()))
	end
end

local function target_id(unit)
	local id = unit and unit:id()

	return id ~= -1 and id or nil
end

function M.dying(unit, attacker)
	local camera = adapters.camera
	if camera and camera.begin_corpse_transition then
		camera.begin_corpse_transition(unit)
	end
	local identity = get_runtime():observer_identity(unit)
	local source_unit = world_target.responsible_unit(attacker)
	candidates[unit:key()] = {
		peer_id = world_target.peer_id(source_unit),
		source_unit = source_unit,
		subject_id = identity and identity.id or unit:id(),
		subject_generation = identity and identity.generation,
	}
end

function M.before_death(dead_unit, attacker)
	local identity = get_runtime():observer_identity(dead_unit)
	local candidate = candidates[dead_unit:key()]
	deaths[dead_unit:key()] = {
		peer_id = candidate and candidate.peer_id or world_target.peer_id(attacker),
		attacker_unit = candidate and candidate.source_unit or world_target.responsible_unit(attacker),
		subject_id = candidate and candidate.subject_id or identity and identity.id or target_id(dead_unit),
		subject_generation = candidate and candidate.subject_generation or identity and identity.generation,
	}
end

function M.died(dead_unit, corpse)
	local key = dead_unit:key()
	local id = corpse and corpse.u_id or target_id(dead_unit)
	local death = deaths[key]
	local peer_id = death and death.peer_id

	deaths[key] = nil
	candidates[key] = nil

	if id then
		local runtime = get_runtime()
		if death and death.subject_id then
			runtime:unregister_observer("guard", death.subject_id)
		end
		local active = runtime:target_for_unit(dead_unit)
		if active and active.kind ~= "corpse" then
			world_target.unregister_unit(dead_unit)
		end
		local config = world_target.config(dead_unit, "enemy_law_corpse_sneak")
		local prediction_config = Network:is_client() and world_target.corpse_prediction_config(dead_unit)
		local session = managers.network and managers.network:session()
		local local_peer = session and session.local_peer and session:local_peer()
		local subject_id = death and death.subject_id or id
		local subject_generation = death and death.subject_generation
		local native_key = "corpse:" .. subject_id .. ":" .. (subject_generation or 0)
		local spec = {
			kind = "corpse",
			unit = dead_unit,
			canonical_unit = dead_unit,
			id = id,
			owner_peer_id = peer_id,
			cause = "corpse_death",
			native_key = native_key,
			source_unit = death and death.attacker_unit,
			subject_id = subject_id,
			subject_generation = subject_generation,
			config = config,
		}
		if Network:is_server() then
			world_target.register("corpse", id, dead_unit, peer_id, "enemy_law_corpse_sneak")
			runtime:confirm_prediction(spec)
		elseif prediction_config and local_peer and peer_id == local_peer:id() then
			spec.config = prediction_config
			spec.attention = world_target.prediction_attention(dead_unit, prediction_config)
			if runtime:predict_target(spec) then
				runtime:register_target("corpse", id, dead_unit)
			else
				world_target.register("corpse", id, dead_unit, nil, "enemy_law_corpse_sneak")
			end
		else
			world_target.register("corpse", id, dead_unit, nil, "enemy_law_corpse_sneak")
		end
	end
	local camera = adapters.camera
	if camera and camera.end_corpse_transition then
		camera.end_corpse_transition(dead_unit)
	end
end

function M.destroyed(unit)
	candidates[unit:key()] = nil
	world_target.unregister_unit(unit)
end

function M.removed(id)
	get_runtime():unregister_target("corpse", id)
end

return M
