local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))

local installers = {
	["lib/network/handlers/unitnetworkhandler"] = function()
		CST.module("network/hooks/handler"):install()
	end,
	["lib/managers/menumanager"] = function()
		CST.module("network/hooks/notice"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
