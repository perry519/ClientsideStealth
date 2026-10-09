local path, log_event = ...
local M = {}
local VERSION = 1

M.FEATURES = {
	"detection",
	"player",
	"bag",
	"corpse",
	"hostage",
	"vehicle",
	"drill",
	"prop",
	"npc",
	"intimidation",
	"dart",
	"bag_handling",
	"equipment",
	"camera_loop",
	"bag_secure",
}

local known = { enabled = true, lua_networking = false }
for _, name in ipairs(M.FEATURES) do
	known[name] = true
end
known.detection = nil

local values = {}
for name, default in pairs(known) do
	values[name] = default
end

function M.get(name)
	assert(known[name] ~= nil, "ClientsideStealth: unknown setting " .. tostring(name))
	return values[name]
end

local function save()
	if not path then
		return true
	end
	local file = io.open(path, "w")
	if not file then
		return false
	end
	local data = { version = VERSION }
	for name, value in pairs(values) do
		data[name] = value
	end
	local written = file:write(json.encode(data))
	return file:close() and written ~= nil
end

function M.set(name, value)
	assert(known[name] ~= nil, "ClientsideStealth: unknown setting " .. tostring(name))
	assert(type(value) == "boolean", "ClientsideStealth: setting " .. name .. " must be boolean")
	if values[name] == value then
		return false
	end
	values[name] = value
	if not save() then
		log_event("settings_save_failed", { "path", tostring(path) })
	end
	return true
end

function M.load()
	local file = path and io.open(path, "r")
	if not file then
		return false
	end
	local text = file:read("*a")
	file:close()
	local ok, data = pcall(json.decode, text)
	if not ok or type(data) ~= "table" or data.version ~= VERSION then
		log_event("settings_ignored", { "path", tostring(path) })
		return false
	end
	for name in pairs(known) do
		if type(data[name]) == "boolean" then
			values[name] = data[name]
		end
	end
	return true
end

return M
