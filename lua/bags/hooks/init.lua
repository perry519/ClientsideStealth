local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
local module = CST.module

local installers = {
	["lib/units/props/carrydata"] = function()
		module("bags/hooks/carry"):install()
	end,
	["lib/units/props/smalllootbase"] = function()
		module("bags/hooks/small_loot"):install()
	end,
	["lib/units/interactions/interactionext"] = function()
		module("bags/hooks/interaction"):install()
	end,
	["lib/managers/mission/elementareatrigger"] = function()
		module("bags/hooks/mission"):install()
	end,
	["lib/network/handlers/unitnetworkhandler"] = function()
		module("bags/hooks/network"):install()
	end,
	["lib/managers/playermanager"] = function()
		module("bags/hooks/player"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
