local devices = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	local original = SpyCameraInteractionExt.interact
	SpyCameraInteractionExt.interact = function(interaction, ...)
		local result = original(interaction, ...)
		if result then
			devices.spy_camera_interacted(interaction._unit)
		end
		return result
	end
end

return M
