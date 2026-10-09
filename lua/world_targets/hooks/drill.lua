local drill = ...
local M = {}

local function is_drill(base)
	return base and Drill and base._set_attention_state == Drill._set_attention_state
end

function M:install_drill()
	if self._drill_installed then
		return
	end
	self._drill_installed = true
	for _, name in ipairs({ "_set_attention_state", "update_attention_settings" }) do
		Hooks:PostHook(Drill, name, "clientsidestealth_drill_" .. name, drill.sync)
	end
	Hooks:PreHook(Drill, "pre_destroy", "clientsidestealth_drill_destroy", function(base)
		drill.removed(base)
	end)
	Hooks:PreHook(Drill, "on_melee_hit", "clientsidestealth_drill_melee", function(base, peer_id)
		base._cst_melee_peer_id = peer_id
	end)
	Hooks:PostHook(Drill, "on_melee_hit", "clientsidestealth_drill_melee_done", function(base)
		base._cst_melee_peer_id = nil
	end)
	Hooks:PostHook(Drill, "on_melee_hit_success", "clientsidestealth_drill_melee_owner", function(base)
		if base._cst_melee_peer_id then
			drill.set_owner(base, base._cst_melee_peer_id)
			drill.sync(base)
		end
	end)
end

function M:install_interaction()
	if self._interaction_installed then
		return
	end
	self._interaction_installed = true
	Hooks:PreHook(
		MissionDoorDeviceInteractionExt,
		"server_place_mission_door_device",
		"clientsidestealth_drill_owner",
		function(interaction, player)
			local base = interaction._unit:base()
			if is_drill(base) then
				drill.placed_by(base, player)
			end
		end
	)
	Hooks:PostHook(
		MissionDoorDeviceInteractionExt,
		"server_place_mission_door_device",
		"clientsidestealth_drill_assign",
		function(interaction)
			local base = alive(interaction._unit) and interaction._unit:base()
			if is_drill(base) then
				drill.sync(base)
			end
		end
	)
end

return M
