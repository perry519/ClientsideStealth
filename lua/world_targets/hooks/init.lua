local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
local module = CST.module
local enemy = module("world_targets/hooks/enemy")
local npc_ai = module("world_targets/hooks/npc_ai")

local installers = {
	["lib/managers/sequencemanager"] = function()
		npc_ai:install_sequence(CoreSequenceManager.AlertElement)
		module("world_targets/hooks/props"):install_sequence(CoreSequenceManager.AttentionElement)
	end,
	["lib/units/props/aiattentionobject"] = function()
		module("world_targets/hooks/props"):install_attention(AIAttentionObject)
	end,
	["lib/network/base/handlers/connectionnetworkhandler"] = function()
		npc_ai:install_alert_sender(ConnectionNetworkHandler)
	end,
	["lib/units/interactions/interactionext"] = function()
		module("world_targets/hooks/pager").install_completion()
		module("world_targets/hooks/drill"):install_interaction()
		module("world_targets/hooks/props"):install_interaction(UseInteractionExt)
	end,
	["lib/units/props/drill"] = function()
		module("world_targets/hooks/drill"):install_drill()
	end,
	["lib/units/enemies/cop/copdamage"] = function()
		enemy:install_damage(CopDamage, "enemy")
	end,
	["lib/units/civilians/civiliandamage"] = function()
		enemy:install_damage(CivilianDamage, "civilian")
	end,
	["lib/units/enemies/cop/huskcopdamage"] = function()
		enemy:install_damage(HuskCopDamage, "husk_enemy")
	end,
	["lib/units/civilians/huskciviliandamage"] = function()
		enemy:install_damage(HuskCivilianDamage, "husk_civilian")
	end,
	["lib/managers/enemymanager"] = function()
		enemy:install()
	end,
	["lib/units/enemies/cop/copbrain"] = function()
		npc_ai:install_surrender()
		module("world_targets/hooks/pager").install_host_completion()
	end,
	["lib/managers/group_ai_states/groupaistatebase"] = function()
		npc_ai:install_groupai()
	end,
	["lib/units/enemies/cop/logics/coplogicidle"] = function()
		npc_ai:install_coplogic()
	end,
	["lib/units/civilians/logics/civilianlogicidle"] = function()
		npc_ai:install_civilianlogic()
		module("detection/hooks/engine")("civilianlogic")
	end,
	["lib/units/enemies/cop/copmovement"] = function()
		npc_ai:install_movement()
	end,
	["lib/units/civilians/civilianbrain"] = function()
		module("world_targets/hooks/civilian"):install()
	end,
	["lib/units/weapons/raycastweaponbase"] = function()
		npc_ai:install_dart(DazingInstantBulletBase)
	end,
	["lib/network/handlers/unitnetworkhandler"] = function()
		module("world_targets/hooks/civilian"):install_tie_sender()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
