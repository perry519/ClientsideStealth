local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))

local installers = {
	["lib/units/props/securitycamera"] = function()
		CST.module("cameras/hooks/security_camera"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
