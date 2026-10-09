local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))

local installers = {
	["lib/units/beings/player/playermovement"] = function()
		CST.module("players/hooks/movement"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
