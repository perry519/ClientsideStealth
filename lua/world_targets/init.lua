local load_module, get_runtime, adapters, restoring_call = ...

local registry = load_module("world_targets/registry", get_runtime, adapters)
load_module("world_targets/attention", registry, get_runtime, adapters)
local npc = load_module("world_targets/npc", registry, get_runtime, adapters)
local props = load_module("world_targets/props", registry, get_runtime, load_module("detection/records"))
load_module("world_targets/hooks/npc_ai", npc, restoring_call)
load_module("world_targets/hooks/pager", load_module("world_targets/pager", registry, get_runtime))
load_module("world_targets/hooks/civilian", load_module("world_targets/hostage", registry, get_runtime))
load_module("world_targets/hooks/enemy", load_module("world_targets/corpse", registry, get_runtime, adapters))
load_module("world_targets/hooks/drill", load_module("world_targets/drill", registry))
load_module("world_targets/hooks/props", props)

return { registry = registry, npc = npc }
