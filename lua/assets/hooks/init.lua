local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
assert(
	RequiredScript == "lib/managers/dynamicresourcemanager",
	"ClientsideStealth: unhandled hook " .. tostring(RequiredScript)
)
CST.module("assets/hooks/resources"):install()
