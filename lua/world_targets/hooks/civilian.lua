local hostage = ...
local M = {}

function M:install_tie_sender()
	if self._tie_sender_installed then
		return
	end
	self._tie_sender_installed = true
	Hooks:PreHook(
		UnitNetworkHandler,
		"unit_tied",
		"clientsidestealth_tie_sender",
		function(handler, unit, aggressor, _, sender)
			if not alive(unit) or not unit:brain() then
				return
			end
			local peer = sender and handler._verify_sender(sender)
			unit:brain()._cst_tie_peer_id = peer and peer:unit() == aggressor and peer:id() or false
		end
	)
	Hooks:PostHook(UnitNetworkHandler, "unit_tied", "clientsidestealth_clear_tie_sender", function(_, unit)
		if alive(unit) and unit:brain() then
			unit:brain()._cst_tie_peer_id = nil
		end
	end)
end

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PreHook(CopBrain, "on_tied", "clientsidestealth_capture_civilian_tie", function(brain)
		brain._cst_was_tied = brain._logic_data and brain._logic_data.is_tied == true
	end)
	Hooks:PostHook(CopBrain, "on_tied", "clientsidestealth_register_tied_civilian", function(brain, aggressor, not_tied)
		if
			not not_tied
			and not brain._cst_was_tied
			and brain._logic_data
			and brain._logic_data.is_tied
			and managers.enemy:is_civilian(brain._unit)
		then
			hostage.tied(brain._unit, brain._cst_tie_peer_id, aggressor)
		end
		brain._cst_was_tied = nil
	end)
	Hooks:PostHook(
		CivilianBrain,
		"on_hostage_move_interaction",
		"clientsidestealth_assign_hostage_command",
		function(brain, instigator, command)
			local accepted = Hooks:GetReturn() == true
			if accepted and (command == "release" or command == "move" or command == "stay") then
				hostage.commanded(brain._unit, instigator, command)
			end
		end
	)
	Hooks:PostHook(CopBrain, "on_trade", "clientsidestealth_unregister_traded_hostage", function(brain)
		if managers.enemy:is_civilian(brain._unit) then
			hostage.released(brain._unit)
		end
	end)
end

return M
