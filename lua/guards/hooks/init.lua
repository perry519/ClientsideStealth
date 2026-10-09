local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
local module = CST.module

local installers = {
	["lib/units/enemies/cop/copbrain"] = function()
		module("guards/hooks/cop_brain"):install()
	end,
	["lib/units/enemies/cop/huskcopbrain"] = function()
		module("guards/hooks/husk_brain"):install()
	end,
	["lib/units/weapons/raycastweaponbase"] = function()
		module("guards/hooks/weapon"):install_collision()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
