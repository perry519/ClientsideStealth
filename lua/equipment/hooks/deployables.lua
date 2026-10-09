local ecm, placement, supplies, restoring_call = ...
local M = {}

local function without_sound(unit, event_name, original, ...)
	local source = unit:sound_source()
	local sound_class = type(SoundSource) == "userdata" and getmetatable(SoundSource) or SoundSource
	local post_event = sound_class.post_event
	local suppressed = false
	sound_class.post_event = function(sound, event, ...)
		if sound == source and event == event_name then
			suppressed = true
			return
		end
		return post_event(sound, event, ...)
	end
	local result = restoring_call(function()
		sound_class.post_event = post_event
	end, original, ...)
	return result, suppressed
end

function M:install_trip_mine_sound()
	if self._trip_mine_sound_installed then
		return
	end
	self._trip_mine_sound_installed = true
	local original = UnitNetworkHandler.sync_trip_mine_setup
	UnitNetworkHandler.sync_trip_mine_setup = function(handler, unit, sensor_upgrade, peer_id, ...)
		if placement:predicted_trip_mine(unit, peer_id) then
			return without_sound(unit, "trip_mine_attach", original, handler, unit, sensor_upgrade, peer_id, ...)
		end
		return original(handler, unit, sensor_upgrade, peer_id, ...)
	end
end

function M:install_bag_sound(class, kind)
	self._bag_sounds_installed = self._bag_sounds_installed or {}
	if self._bag_sounds_installed[kind] then
		return
	end
	self._bag_sounds_installed[kind] = true
	local original = class.init
	class.init = function(base, unit, ...)
		if not placement:predicted_bag(kind, unit) then
			return original(base, unit, ...)
		end

		local result, suppressed = without_sound(unit, "ammo_bag_drop", original, base, unit, ...)
		base._cst_deferred_drop = suppressed or nil
		return result
	end
end

function M:install_grenade()
	if self._grenade_installed then
		return
	end
	self._grenade_installed = true
	function GrenadeCrateDeployableBase:sync_setup(_, peer_id)
		self:set_server_information(peer_id)
	end
	Hooks:PostHook(
		GrenadeCrateDeployableBase,
		"set_server_information",
		"ClientsideStealthEquipment_grenade_setup",
		function(base, peer_id)
			if not Network:is_server() then
				placement:grenade_arrive(base._unit, peer_id)
				return
			end
			local session = managers.network:session()
			local peer = session and session:peer(peer_id)
			if peer and supplies.accepts_owner_setup(peer_id) then
				session:send_to_peer_synched(peer, "sync_equipment_setup", base._unit, 0, peer_id)
			end
		end
	)
end

function M:install_ecm()
	if self._ecm_installed then
		return
	end
	self._ecm_installed = true
	Hooks:PostHook(ECMJammerBase, "setup", "clientsidestealth_ecm_setup", ecm.trim_battery)
end

return M
