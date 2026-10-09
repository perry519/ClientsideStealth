local load_module, get_runtime, control, restoring_call, Log = ...

local ecm = load_module("equipment/ecm", get_runtime, control)
local proxy = load_module("equipment/proxy", Log)
local supplies = load_module("equipment/supplies", control, get_runtime, Log, proxy)
local devices = load_module("equipment/devices", control, proxy, restoring_call)
local placement = load_module("equipment/placement", ecm, get_runtime, control, supplies, devices)
load_module("equipment/hooks/network", placement, supplies, load_module("shared/from_host"))
load_module("equipment/hooks/deployables", ecm, placement, supplies, restoring_call)
load_module("equipment/hooks/player", ecm, placement)
load_module("equipment/hooks/interaction", devices)

return { ecm = ecm, placement = placement }
