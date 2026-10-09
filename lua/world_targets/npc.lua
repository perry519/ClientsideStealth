local world_target, get_runtime, adapters = ...
local M = {}
local units = {}

local function clear_session()
	for key in pairs(units) do
		units[key] = nil
	end
end
local function cancel_prediction(unit, reason)
	if reason ~= "accepted" and alive(unit) and adapters.guard and adapters.guard.clear_local_alert then
		adapters.guard.clear_local_alert(unit)
	end
end

local function source_for(unit)
	local runtime = get_runtime()
	local source = unit and runtime:target_for_unit(unit)
	return source and source.kind and source.id and source or nil
end

local function npc_config(unit)
	local civilian = CopDamage.is_civilian(unit:base()._tweak_table)
	local presets = civilian and { "civ_enemy_cbt", "civ_civ_cbt", "civ_murderer_cbt" }
		or { "enemy_team_cbt", "enemy_enemy_cbt", "enemy_civ_cbt" }
	table.sort(presets)
	return world_target.projected_config(unit, presets)
end

local function spec(unit, source_unit, cause, observer_kind, observer_id)
	local runtime = get_runtime()
	if not runtime:is_active() or not alive(unit) or not alive(source_unit) then
		return nil
	end
	local id = unit:id()
	local source = source_for(source_unit)
	if id == -1 or not source or source.unit == unit then
		return nil
	end
	local config = npc_config(unit)
	local attention = config and world_target.prediction_attention(unit, config)
	if not attention then
		return nil
	end
	return {
		kind = "npc",
		id = id,
		unit = unit,
		source = source,
		source_unit = source_unit,
		cause = cause == "npc_alert" and source.kind == "player" and "player_alert" or cause,
		config = config,
		attention = attention,
		observer_kind = observer_kind,
		observer_id = observer_id,
	}
end

function M.predict(unit, source_unit, cause, observer_kind, observer_id, mark_feature)
	local runtime = get_runtime()
	if Network:is_server() or runtime:target_for_unit(unit) or runtime:prediction_for_unit(unit) then
		return nil
	end
	local candidate = spec(unit, source_unit, cause, observer_kind, observer_id)
	if candidate then
		candidate.mark_feature = mark_feature
	end
	return candidate and runtime:predict_target(candidate) or nil
end

function M.confirm(unit, source_unit, cause, observer_kind, observer_id)
	local runtime = get_runtime()
	if not Network:is_server() or not runtime:is_active() or not alive(unit) or unit:id() == -1 then
		return nil
	end
	local existing = runtime:target_for_unit(unit)
	local owner = existing and runtime:target_owner(existing.kind, existing.id)
	local confirmed, pending_source
	if existing then
		confirmed, pending_source = runtime:native_alert_for(existing)
	end
	if
		existing
		and (
			existing.kind ~= "npc"
			or confirmed
			or pending_source and pending_source ~= source_unit
			or owner ~= runtime.host_peer_id
		)
	then
		return existing
	end
	local config = not existing and npc_config(unit)
	if config and not existing then
		runtime:register_target("npc", unit:id(), unit, { config = config })
	end
	local candidate = spec(unit, source_unit, cause, observer_kind, observer_id)
	if not candidate then
		if alive(source_unit) and source_unit ~= unit and not source_for(source_unit) then
			runtime:defer_native_alert(unit, source_unit, cause, observer_kind, observer_id)
		end
		return runtime:target_for_unit(unit)
	end
	return runtime:confirm_prediction(candidate)
end

function M.bind(unit)
	local runtime = get_runtime()
	if alive(unit) and unit:id() ~= -1 then
		units["CopBrain" .. tostring(unit:key())] = unit
		runtime:bind_predicted_unit("npc", unit:id(), unit)
	end
end

function M.unbind(unit)
	local runtime = get_runtime()
	if not unit then
		return
	end
	units["CopBrain" .. tostring(unit:key())] = nil
	runtime:cancel_prediction_for_unit(unit, "npc_lifecycle")
	local target = runtime:target_for_unit(unit)
	if target and target.kind == "npc" then
		runtime:unregister_target(target.kind, target.id)
	end
end

function M.sync_surrender(unit, surrendered, aggressor)
	local runtime = get_runtime()
	if not runtime:is_active() or not alive(unit) or unit:id() == -1 then
		return
	end
	local target = runtime:target_for_unit(unit)
	if target and target.kind ~= "npc" then
		return
	end
	if not Network:is_server() then
		local bound = target or surrendered and runtime:register_target("npc", unit:id(), unit)
		if bound then
			local config = surrendered and world_target.corpse_prediction_config(unit) or npc_config(unit)
			if config and runtime:prediction_for_unit(unit) then
				runtime:update_prediction_attention(unit, config)
			elseif config then
				adapters.world_target.apply_config(unit, config)
			end
		end
		return bound
	end
	if not surrendered and not target then
		return
	end
	local config = world_target.config(unit)
	if not config then
		if target then
			runtime:unregister_target("npc", unit:id())
		end
		return
	end
	target = runtime:register_target("npc", unit:id(), unit, { config = config })
	if target and surrendered then
		local peer_id = alive(aggressor) and world_target.peer_id(aggressor) or nil
		runtime:assign_owner("npc", unit:id(), peer_id)
	end
	return target
end

local adapter_registered = false
function M.register_adapter()
	if adapter_registered then
		return
	end
	adapter_registered = true
	adapters:register("npc", {
		clear_session = clear_session,
		cancel_prediction = cancel_prediction,
		confirm = M.confirm,
		bind = M.bind,
	})
end

function M.predict_sound(state, alert, source_unit)
	local runtime = get_runtime()
	if Network:is_server() or not runtime:is_active() then
		return
	end
	source_unit = source_unit or alert and alert[5]
	if not source_for(source_unit) or not CopLogicBase.is_alert_aggressive(alert[1]) then
		return
	end
	local radius_sq = alert[2] and alert[3] and alert[3] * alert[3]
	local filter = state:get_unit_type_filter("criminals_enemies_civilians")
	for key, unit in pairs(units) do
		if not alive(unit) then
			units[key] = nil
		else
			local brain = unit:brain()
			local movement = unit:movement()

			if
				unit ~= alert[5]
				and brain
				and movement
				and not brain._dead
				and not brain._surrendered
				and not brain._converted
				and not brain._is_hostage
				and movement:cool()
				and not runtime:target_for_unit(unit)
				and not runtime:prediction_for_unit(unit)
				and managers.navigation:check_access(filter, alert[4], nil)
				and (not radius_sq or mvector3.distance_sq(alert[2], movement:m_head_pos()) < radius_sq)
				and not CopLogicBase._chk_alert_obstructed(movement:m_head_pos(), alert)
				and not (brain._is_civilian and unit:base().unintimidateable)
			then
				if M.predict(unit, source_unit, "npc_alert", "sound", nil) then
					adapters.guard.show_local_alert(unit, source_unit)
				end
			end
		end
	end
end

function M.predict_intimidation(unit, aggressor)
	if
		managers.enemy:is_civilian(unit)
		and unit:movement():cool()
		and M.predict(unit, aggressor, "npc_alert", "guard", unit:id(), "player")
	then
		adapters.guard.show_local_alert(unit, aggressor)
	end
end

function M.attributed_source(unit, source)
	local runtime = get_runtime()
	if
		alive(unit)
		and alive(source)
		and not unit:brain()
		and not runtime:target_for_unit(unit)
		and runtime:delegates(world_target.peer_id(source), "prop")
	then
		return source
	end
	return unit
end

function M.cooled(unit)
	M.unbind(unit)
	if Network:is_server() and alive(unit) then
		get_runtime():restart_observer("guard", unit:id(), unit)
	end
	M.bind(unit)
end

function M.logic_changed(brain)
	local data = brain._logic_data
	local internal = data and data.internal_data
	local surrendered = data and data.name == "intimidated" and internal and internal.is_hostage == true
	local was_surrendered = brain._cst_surrendered
	brain._cst_surrendered = surrendered or nil
	if surrendered or was_surrendered then
		M.sync_surrender(brain._unit, surrendered == true, surrendered and internal.aggressor_unit)
	end
end

return M
