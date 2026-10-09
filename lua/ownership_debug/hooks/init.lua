local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))

local installers = {
	["lib/units/contourext"] = function()
		CST.module("ownership_debug/hooks/contour"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
