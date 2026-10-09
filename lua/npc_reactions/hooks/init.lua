local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))

local installers = {
	["lib/units/enemies/cop/copbrain"] = function()
		CST.module("npc_reactions/hooks/brain"):install_host()
	end,
	["lib/units/enemies/cop/huskcopbrain"] = function()
		CST.module("npc_reactions/hooks/brain"):install()
	end,
	["lib/units/beings/player/states/playerstandard"] = function()
		CST.module("npc_reactions/hooks/player"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
