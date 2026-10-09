local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
local install_engine = CST.module("detection/hooks/engine")

local installers = {
	["lib/managers/group_ai_states/groupaistatebase"] = function()
		install_engine("groupai")
	end,
	["lib/units/enemies/cop/logics/coplogicbase"] = function()
		install_engine("coplogic")
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
