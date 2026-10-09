local dart = ...
local M = {}

function M:install_collision()
	if self._collision_installed then
		return
	end
	self._collision_installed = true
	local original = DazingInstantBulletBase.on_collision
	DazingInstantBulletBase.on_collision = function(bullet, col_ray, weapon, shooter, damage, blank, no_sound)
		local unit = col_ray and col_ray.unit
		local attempt = unit and not blank and dart.prepare_daze(unit, shooter, weapon)
		local result = original(bullet, col_ray, weapon, shooter, damage, blank, no_sound)
		if result and result.variant == "daze" then
			dart.predict_alert(unit, shooter, weapon, col_ray)
			if attempt then
				dart.apply_daze(unit, attempt)
			end
		end
		return result
	end
end

return M
