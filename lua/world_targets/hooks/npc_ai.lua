local npc, restoring_call = ...
local M = {}

local giveaway_source
local visual_unit

local prop_unit, prop_source

local dart_unit, dart_shooter

local function alert_source(alert)
	local unit = alert[5]
	if alert[1] == "aggression" and unit == prop_unit then
		return npc.attributed_source(unit, prop_source)
	end
	if alert[1] == "aggression" and unit == dart_unit and alive(dart_shooter) then
		return dart_shooter
	end
	return unit
end

local function with_prop_source(unit, source, fn, ...)
	local previous_unit, previous_source = prop_unit, prop_source
	prop_unit, prop_source = unit, source
	return restoring_call(function()
		prop_unit, prop_source = previous_unit, previous_source
	end, fn, ...)
end

function M:install_sequence(class)
	if self._sequence_installed then
		return
	end
	self._sequence_installed = true
	local activate = class.activate_callback
	function class:activate_callback(env, ...)
		return with_prop_source(env.dest_unit, env.src_unit, activate, self, env, ...)
	end
end

function M:install_alert_sender(class)
	if self._alert_sender_installed then
		return
	end
	self._alert_sender_installed = true
	local propagate = class.propagate_alert
	function class:propagate_alert(kind, pos, radius, filter, aggressor, head, sender)
		local peer = self._verify_gamestate(self._gamestate_filter.any_ingame) and self._verify_sender(sender)
		return with_prop_source(
			aggressor,
			peer and peer:unit(),
			propagate,
			self,
			kind,
			pos,
			radius,
			filter,
			aggressor,
			head,
			sender
		)
	end
end

function M:install_dart(class)
	if self._dart_installed then
		return
	end
	self._dart_installed = true
	local original = class.sync_on_collision
	class.sync_on_collision = function(col_ray, weapon, shooter, ...)
		local previous_unit, previous_shooter = dart_unit, dart_shooter
		dart_unit, dart_shooter = col_ray and col_ray.unit, shooter
		return restoring_call(function()
			dart_unit, dart_shooter = previous_unit, previous_shooter
		end, original, col_ray, weapon, shooter, ...)
	end
end

function M:install_surrender()
	npc.register_adapter()
	if self._surrender_installed then
		return
	end
	self._surrender_installed = true

	local intimidated = CopBrain.on_intimidated
	function CopBrain:on_intimidated(amount, aggressor, ...)
		local was_cool = managers.enemy:is_civilian(self._unit) and self._unit:movement():cool()
		local result = intimidated(self, amount, aggressor, ...)
		if was_cool and not self._unit:movement():cool() then
			npc.confirm(self._unit, aggressor, "npc_alert", "guard", self._unit:id())
		end
		return result
	end
	Hooks:PostHook(CopBrain, "set_logic", "ClientsideStealthTrackGuardSurrender", function(brain)
		if not managers.enemy:is_civilian(brain._unit) then
			npc.logic_changed(brain)
		end
	end)
end

function M:install_groupai()
	npc.register_adapter()
	if self._groupai_installed then
		return
	end
	self._groupai_installed = true
	local original = GroupAIStateBase.analyse_giveaway
	GroupAIStateBase.analyse_giveaway = function(trigger, source, ...)
		if visual_unit then
			giveaway_source = source
		end
		return original(trigger, source, ...)
	end
	local propagate = GroupAIStateBase.propagate_alert
	function GroupAIStateBase:propagate_alert(alert, ...)
		npc.predict_sound(self, alert, alert_source(alert))
		return propagate(self, alert, ...)
	end
end

function M:install_movement()
	npc.register_adapter()
	if self._movement_installed then
		return
	end
	self._movement_installed = true
	local original = CopMovement.set_cool
	function CopMovement:set_cool(state, ...)
		local was_cool = self:cool()
		local result = original(self, state, ...)
		if not was_cool and self:cool() then
			npc.cooled(self._unit)
		elseif was_cool and not self:cool() and Network:is_server() and visual_unit == self._unit then
			npc.confirm(self._unit, giveaway_source, "npc_alert", "guard", self._unit:id())
		end
		return result
	end
end

local function confirm_alert(data, alert_data, was_cool, ...)
	if was_cool and not data.unit:movement():cool() then
		npc.confirm(data.unit, alert_source(alert_data), "npc_alert", "guard", data.unit:id())
	end
	return ...
end

function M:install_coplogic()
	npc.register_adapter()
	if self._coplogic_installed then
		return
	end
	self._coplogic_installed = true
	local priority = CopLogicIdle._get_priority_attention
	function CopLogicIdle._get_priority_attention(data, ...)
		local previous_unit, previous_source = visual_unit, giveaway_source
		visual_unit, giveaway_source = data.unit, nil
		return restoring_call(function()
			visual_unit, giveaway_source = previous_unit, previous_source
		end, priority, data, ...)
	end
	local alert = CopLogicIdle.on_alert
	function CopLogicIdle.on_alert(data, alert_data, ...)
		local was_cool = data.unit:movement():cool()
		return confirm_alert(data, alert_data, was_cool, alert(data, alert_data, ...))
	end
end

function M:install_civilianlogic()
	npc.register_adapter()
	if self._civilianlogic_installed then
		return
	end
	self._civilianlogic_installed = true
	local alert = CivilianLogicIdle.on_alert
	function CivilianLogicIdle.on_alert(data, alert_data, ...)
		local was_cool = data.unit:movement():cool()
		return confirm_alert(data, alert_data, was_cool, alert(data, alert_data, ...))
	end
end

return M
