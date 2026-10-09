local ecm, placement = ...
local M = {}

function M:install()
	if self._installed or not PlayerEquipment then
		return
	end
	self._installed = true
	Hooks:PreHook(PlayerEquipment, "destroy", "ClientsideStealthEquipment_destroy", function()
		placement:clear_pending()
		ecm.player_destroyed()
	end)
end

return M
