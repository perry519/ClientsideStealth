local debug_view = ...
local M = {}

function M:install()
	if not ContourExt or ContourExt._cst_ownership_debug then
		return
	end
	ContourExt._cst_ownership_debug = true

	ContourExt._types[debug_view.WORLD] = { priority = 0, unique = true }
	ContourExt._types[debug_view.CHARACTER] = { priority = 0, unique = true, material_swap_required = true }
	local original = ContourExt._upd_opacity
	function ContourExt:_upd_opacity(opacity, ...)
		local top = self._contour_list and self._contour_list[1]
		if top and (top.type == debug_view.WORLD or top.type == debug_view.CHARACTER) then
			opacity = math.min(opacity, 0.3)
		end
		return original(self, opacity, ...)
	end
end

return M
