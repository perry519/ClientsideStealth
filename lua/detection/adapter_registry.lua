local KINDS = { bag = true, camera = true, guard = true, npc = true, player = true, world_target = true }
local Registry = {}

function Registry.register(adapters, kind, methods)
	assert(KINDS[kind], "ClientsideStealth: unknown adapter kind " .. tostring(kind))
	local contributed = adapters[kind] or {}
	for name, method in pairs(methods) do
		assert(
			type(method) == "function",
			"ClientsideStealth: adapter " .. kind .. "." .. tostring(name) .. " must be a function"
		)
		contributed[name] = method
	end
	adapters[kind] = contributed
	return contributed
end

return setmetatable({}, { __index = Registry })
