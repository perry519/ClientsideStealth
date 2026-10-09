local occupants = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PostHook(VehicleDrivingExt, "init", "clientsidestealth_register_vehicle", occupants.seats_changed)
	Hooks:PostHook(
		VehicleDrivingExt,
		"place_player_on_seat",
		"clientsidestealth_update_vehicle_seat",
		occupants.seats_changed
	)
	Hooks:PostHook(VehicleDrivingExt, "exit_vehicle", "clientsidestealth_update_vehicle_exit", occupants.seats_changed)
	Hooks:PostHook(
		VehicleDrivingExt,
		"_evacuate_vehicle",
		"clientsidestealth_update_vehicle_evacuation",
		occupants.seats_changed
	)
	Hooks:PreHook(
		VehicleDrivingExt,
		"pre_destroy",
		"clientsidestealth_unregister_vehicle_pre_destroy",
		occupants.removed
	)
end

return M
