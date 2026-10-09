local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))

local installers = {
	["lib/managers/localizationmanager"] = function()
		CST.module("hooks/localization"):install()
	end,
	["lib/units/enemies/cop/copmovement"] = function()
		CST.module("hooks/cop_movement"):install_movement()
	end,
	["lib/units/enemies/cop/huskcopmovement"] = function()
		CST.module("hooks/cop_movement"):install_husk_movement()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
