local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
local network = CST.module("session/hooks/network")
local installers = {
	["lib/network/base/basenetworksession"] = function()
		network:install()
	end,
	["lib/managers/menumanager"] = function()
		network:install_receiver()
		CST.module("session/hooks/menu"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
