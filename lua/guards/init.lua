local load_module, get_runtime, adapters, control, features, world_target, npc, cop_act = ...

local dart = load_module("guards/dart", get_runtime, adapters, control, cop_act, npc)
load_module("guards/hooks/weapon", dart)
local cop = load_module("guards/cop", get_runtime, adapters, npc)
load_module("guards/hooks/cop_brain", cop)
local husk = load_module(
	"guards/husk",
	world_target,
	get_runtime,
	adapters,
	npc,
	dart,
	features,
	load_module("guards/reports", get_runtime),
	cop.create_attention_entry
)
load_module("guards/hooks/husk_brain", husk)

return { dart = dart }
