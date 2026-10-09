local world_target, get_runtime = ...
local M = {}

function M.corpse(unit)
	local corpse = unit and managers.enemy:get_corpse_unit_data_from_key(unit:key())
	return corpse and corpse.u_id and (not corpse.unit or corpse.unit == unit) and corpse or nil
end

local function proof_for(corpse, unit, player)
	return {
		kind = "corpse",
		id = corpse.u_id,
		unit = unit,
		source_unit = player,
		cause = "pager_complete",
		native_key = "pager:" .. tostring(corpse.u_id),
	}
end

function M.capture_host_completion(brain, status, player)
	local corpse = status == "complete" and brain._alarm_pager_data and M.corpse(brain._unit)
	return corpse
			and {
				player = player,
				corpse = corpse,
				successes = managers.groupai:state():get_nr_successful_alarm_pager_bluffs(),
			}
		or nil
end

function M.confirm_host_completion(brain, completion)
	if
		not completion
		or not Network:is_server()
		or managers.groupai:state():get_nr_successful_alarm_pager_bluffs() <= completion.successes
	then
		return
	end

	local corpse = M.corpse(brain._unit)
	if corpse and corpse == completion.corpse then
		local peer_id = world_target.peer_id(completion.player)
		local target = world_target.register("corpse", corpse.u_id, brain._unit, peer_id, "enemy_law_corpse_sneak")
		if target then
			local proof = proof_for(corpse, brain._unit, completion.player)
			proof.owner_peer_id = peer_id
			get_runtime():confirm_prediction(proof)
		end
	end
end

function M.predict_completion(unit, player, corpse)
	if Network:is_server() or not corpse or M.corpse(unit) ~= corpse or not get_runtime():is_active() then
		return
	end
	local config = world_target.corpse_prediction_config(unit)
	if not config or not world_target.peer_id(player) then
		return
	end
	local proof = proof_for(corpse, unit, player)
	proof.config = config
	proof.attention = world_target.prediction_attention(unit, config)
	get_runtime():predict_target(proof)
end

return M
