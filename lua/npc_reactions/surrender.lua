local get_runtime, control, world_target, adapters, surrender_action, reactions, npc = ...
local M = {}
local pending = {}

local settled_hud = {}
local identity_changed

local function corpse_config(config)
	for _, preset in ipairs(config and config.presets or {}) do
		if preset == "enemy_law_corpse_sneak" then
			return true
		end
	end
	return false
end

local function now()
	return TimerManager:game():time()
end

local function clear_settled(unit)
	if settled_hud[unit] then
		settled_hud[unit] = nil
		if alive(unit) then
			adapters.world_target.refresh_attention(unit)
		end
	end
end

local function apply(runtime, unit, config)
	if config and not runtime:update_prediction_attention(unit, config) then
		adapters.world_target.apply_config(unit, config)

		adapters.world_target.refresh_attention(unit)
	end
end

local function resolve(unit, restore, settled_config, restore_hud)
	local entry = pending[unit]
	if not entry then
		return
	end
	pending[unit] = nil
	if not settled_config then
		surrender_action.cancel(unit)
	end
	if not alive(unit) then
		settled_hud[unit] = nil
		return
	end
	local runtime = get_runtime()
	local brain = unit:brain()
	local replaced, revoked = identity_changed(runtime, unit, entry)
	if settled_config and not brain._surrendered then
		entry.hud = nil
		settled_hud[unit] = entry
	elseif
		restore
		and restore_hud ~= false
		and entry.hud
		and not replaced
		and not revoked
		and not unit:character_damage():dead()
		and not brain._dead
		and not brain._surrendered
		and not brain._is_hostage
		and not brain._converted
	then
		adapters.guard.restore_alert(unit, entry.hud)
	end
	if settled_config then
		apply(runtime, unit, settled_config)
	elseif restore then
		local config = runtime:target_config_for_unit(unit)
		apply(runtime, unit, unit:brain()._surrendered and entry.config or config or entry.original)
	end
	runtime:reconcile_surrender_reports(unit)
	runtime:refresh_prediction_reports(unit)
end

local function unbound(entry)
	return not entry.incarnation or entry.incarnation == 0
end

local function adopt_identity(runtime, entry, target)
	local owner, epoch = runtime:target_owner(target.kind, target.id)
	if owner ~= runtime.local_peer_id then
		return false
	end
	entry.incarnation, entry.owner, entry.epoch = target.incarnation, owner, epoch
	return true
end

identity_changed = function(runtime, unit, entry)
	local target = runtime:target_for_unit(unit)
	local replaced = unit:id() ~= entry.id or target and target.kind ~= "npc"
	local revoked = false
	if target and unbound(entry) and target.incarnation and target.incarnation > 0 then
		revoked = not adopt_identity(runtime, entry, target)
	end
	if target and entry.incarnation then
		local owner, epoch = runtime:target_owner(target.kind, target.id)
		replaced = replaced or target.incarnation ~= entry.incarnation
		revoked = revoked or owner ~= entry.owner or epoch ~= entry.epoch
	end
	local cancelled = not target and not (runtime:prediction_for_unit(unit) and runtime:current_npc_alert(unit))
	return replaced, revoked or cancelled
end

local function eligible(runtime, unit, aggressor)
	if not alive(unit) or unit:id() < 0 or not alive(aggressor) or not aggressor:base().is_local_player then
		return false
	end
	local tweak = reactions.intimidatable(unit)
	local surrender = tweak and tweak.surrender
	if not surrender or unit:in_slot(16) or CopDamage.is_civilian(unit:base()._tweak_table) then
		return false
	end
	local state = managers.groupai:state()
	if not state:has_room_for_police_hostage() or not aggressor:movement():team().foes[unit:movement():team().id] then
		return false
	end
	local skill = state:is_enemy_special(unit) and "intimidate_specials" or "intimidate_enemies"
	if not managers.player:has_category_upgrade("player", skill) then
		return false
	end
	local prediction = runtime:prediction_for_unit(unit)
	local alert = runtime:current_npc_alert(unit)
	local target = runtime:target_for_unit(unit)
	local owner = target and runtime:target_owner(target.kind, target.id)
	if
		not (prediction and prediction.kind == "npc" and alert)
		and not (target and target.kind == "npc" and owner == runtime.local_peer_id)
	then
		return false
	end
	local not_cool_t = unit:movement():not_cool_t()
	local alert_age = not_cool_t and now() - not_cool_t
	if alert then
		alert_age = math.max(alert_age or 0, alert.age)
	end
	return surrender.base_chance and surrender.base_chance >= 1
		or surrender.reasons
			and surrender.reasons.pants_down == 1
			and alert_age
			and alert_age < 1.5
			and not state:enemy_weapons_hot()
end

function M.begin(unit, _amount, aggressor)
	npc.predict_intimidation(unit, aggressor)
	local runtime = get_runtime()
	if
		pending[unit]
		or settled_hud[unit]
		or Network:is_server()
		or not runtime:is_active()
		or not control.allows_new_work("intimidation")
		or not managers.groupai:state():whisper_mode()
		or not eligible(runtime, unit, aggressor)
	then
		return false
	end
	local config = world_target.corpse_prediction_config(unit)
	if not config then
		return false
	end
	local original, target = runtime:target_config_for_unit(unit)
	local prediction = runtime:prediction_for_unit(unit)
	local owner, epoch
	if target then
		owner, epoch = runtime:target_owner(target.kind, target.id)
	end
	local entry = {
		id = unit:id(),
		deadline = now() + 10,
		config = config,
		original = original or prediction and prediction.config,
		incarnation = target and target.incarnation,
		owner = owner,
		epoch = epoch,
	}
	pending[unit] = entry
	entry.hud = adapters.guard.suspend_alert(unit)
	apply(runtime, unit, config)
	surrender_action.begin(unit, entry.deadline, function()
		local replaced, revoked = identity_changed(runtime, unit, entry)
		return not replaced and not revoked
	end)
	return true
end

function M.sync(unit, surrendered)
	if not surrendered then
		clear_settled(unit)
		surrender_action.cancel(unit)
		resolve(unit, true)
	end
end

function M.attention_config(unit, fallback)
	local entry = pending[unit]
	if not entry then
		local brain = alive(unit) and unit.brain and unit:brain()
		if brain and brain._surrendered and not brain._converted and fallback and not corpse_config(fallback) then
			return world_target.corpse_prediction_config(unit) or fallback
		end
		return fallback
	end
	if unbound(entry) and fallback and fallback.incarnation then
		local runtime = get_runtime()
		local target = runtime:target_for_unit(unit)
		if target and target.kind == "npc" and target.incarnation == fallback.incarnation then
			adopt_identity(runtime, entry, target)
		end
	end
	if
		fallback
		and fallback.kind == "npc"
		and fallback.id == entry.id
		and fallback.config_revision
		and entry.incarnation
		and entry.incarnation > 0
		and fallback.incarnation == entry.incarnation
	then
		if corpse_config(fallback) then
			entry.settlement = fallback
			return fallback
		end
	end
	return entry.config
end

function M.attention_settings(unit, native_settings, ...)
	local entry = pending[unit] or settled_hud[unit]
	local brain = alive(unit) and unit.brain and unit:brain()
	if not entry and not (brain and brain._surrendered and not brain._converted) then
		return native_settings
	end
	local attention = entry and entry.attention
	if not attention then
		local config = entry and entry.config
		if not config then
			local fallback = world_target.config(unit)
			config = M.attention_config(unit, fallback)
			if config == fallback then
				return native_settings
			end
		end
		attention = world_target.prediction_attention(unit, config)
		if entry then
			entry.attention = attention
		end
	end
	if attention then
		return attention:get_attention(...)
	end
	return native_settings
end

function M.update(t)
	if not next(pending) and not next(settled_hud) and not surrender_action.has_pending() then
		return
	end
	t = t or now()
	local runtime = get_runtime()
	local stopped = not runtime:is_active()
		or not control.allows_new_work("intimidation")
		or not managers.groupai:state():whisper_mode()
	for unit, entry in pairs(settled_hud) do
		local invalid = stopped or not alive(unit) or t >= entry.deadline
		if not invalid then
			local replaced, revoked = identity_changed(runtime, unit, entry)
			local brain = unit:brain()
			invalid = replaced
				or revoked
				or unit:character_damage():dead()
				or brain._surrendered
				or brain._converted
				or brain._is_hostage
		end
		if invalid then
			clear_settled(unit)
		end
	end
	if stopped then
		surrender_action.clear()
	else
		surrender_action.update(t)
	end
	for unit, entry in pairs(pending) do
		if not alive(unit) or unit:character_damage():dead() then
			resolve(unit, false)
		else
			local replaced, revoked = identity_changed(runtime, unit, entry)
			local brain = unit:brain()
			local changed = brain and (brain._converted or brain._is_hostage and not brain._surrendered)
			if replaced or revoked or changed or stopped or t >= entry.deadline then
				resolve(unit, not replaced)
			elseif entry.settlement then
				resolve(unit, false, entry.settlement)
			end
		end
	end
end

function M.clear()
	surrender_action.clear()
	for unit in pairs(pending) do
		resolve(unit, true, nil, false)
	end
	for unit in pairs(settled_hud) do
		clear_settled(unit)
	end
end

function M.suppress_suspicion(unit, suspect, status, state)
	local runtime = get_runtime()
	if Network:is_server() or not runtime:is_active() or not alive(unit) or not unit.brain then
		return false
	end
	local brain = unit:brain()
	local entry = pending[unit] or settled_hud[unit]
	if not entry and not (brain and brain._surrendered) then
		return false
	end
	if
		not brain
		or brain._dead
		or brain._converted
		or unit:character_damage():dead()
		or CopDamage.is_civilian(unit:base()._tweak_table)
	then
		return false
	end
	if entry then
		local replaced, revoked = identity_changed(runtime, unit, entry)
		if replaced or revoked or now() >= entry.deadline then
			return not replaced and brain._surrendered == true and status ~= false and status ~= nil
		end
		if suspect == nil then
			if status == false then
				entry.hud = nil
				return false
			elseif pending[unit] and (status == true or type(status) == "string") then
				entry.hud = {
					status = status,
					expire_t = status == "called" and state._t + 8 or nil,
					persistent = status == "called" or nil,
				}
			end
		end
		return true
	end
	return brain._surrendered == true and status ~= false and status ~= nil
end

function M.pending(unit)
	if pending[unit] then
		return true
	end
	local brain = alive(unit) and unit.brain and unit:brain()
	if not brain or not brain._surrendered or brain._converted then
		return false
	end
	local config, target = get_runtime():target_config_for_unit(unit)
	return target
			and target.kind == "npc"
			and (not config or config.incarnation ~= target.incarnation or not corpse_config(config))
		or false
end

adapters:register("npc", {
	surrender_attention_config = M.attention_config,
	surrender_attention_settings = M.attention_settings,
	surrender_pending = M.pending,
	suppress_surrender_suspicion = M.suppress_suspicion,
	update_surrender_prediction = M.update,
	clear_surrender_prediction = M.clear,
})
return M
