local mod_path = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:Add("LocalizationManagerPostInit", "cst_load_localization", function(loc)
		loc:load_localization_file(mod_path .. "loc/en.json")
	end)
end

return M
