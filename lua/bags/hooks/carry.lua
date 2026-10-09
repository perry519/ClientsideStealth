local bag_lifecycle, Unit = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PostHook(CarryData, "_update_teleport", "clientsidestealth_bag_throw_motion", function(carry)
		Unit.update_throw(carry)
	end)
	Hooks:PostHook(CarryData, "init", "clientsidestealth_register_bag", function(_, unit)
		bag_lifecycle:spawned(unit)
	end)
	Hooks:PostHook(CarryData, "load", "clientsidestealth_register_loaded_bag", function(carry)
		bag_lifecycle:loaded(carry._unit)
	end)
	Hooks:PostHook(CarryData, "set_latest_peer_id", "clientsidestealth_assign_bag", function(carry)
		bag_lifecycle:thrown(carry._unit, carry:latest_peer_id())
	end)

	Hooks:PreHook(CarryData, "set_value", "clientsidestealth_bag_secured", function(carry, value)
		if value == 0 and (carry:value() or 0) > 0 then
			bag_lifecycle:secured(carry._unit)
		end
	end)
	Hooks:PreHook(CarryData, "pre_destroy", "clientsidestealth_unregister_bag", function(carry)
		bag_lifecycle:destroyed(carry._unit)
	end)
	Hooks:PreHook(CarryData, "link_to", "clientsidestealth_bag_secure_pickup", function(carry)
		bag_lifecycle:picked_up(carry._unit)
	end)
end

return M
