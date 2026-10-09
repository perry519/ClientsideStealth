local corpse = ...
local M = {}

function M:install_damage(class, label)
	Hooks:PreHook(class, "die", "clientsidestealth_capture_" .. label .. "_candidate", function(damage, attack_data)
		corpse.dying(damage._unit, attack_data and attack_data.attacker_unit)
	end)

	Hooks:PostHook(class, "_on_damage_received", "clientsidestealth_bag_ready_" .. label, function(damage, damage_info)
		corpse.damage_received(damage._unit, damage_info)
	end)
end

function M:install()
	if self._installed then
		return
	end
	self._installed = true

	local function before_death(_, dead_unit, damage_info)
		corpse.before_death(dead_unit, damage_info and damage_info.attacker_unit)
	end

	local function after_death(enemies, dead_unit)
		corpse.died(dead_unit, enemies:get_corpse_unit_data_from_key(dead_unit:key()))
	end

	Hooks:PreHook(EnemyManager, "on_enemy_died", "clientsidestealth_capture_enemy_death", before_death)
	Hooks:PostHook(EnemyManager, "on_enemy_died", "clientsidestealth_register_enemy_corpse", after_death)
	Hooks:PreHook(EnemyManager, "on_civilian_died", "clientsidestealth_capture_civilian_death", before_death)
	Hooks:PostHook(EnemyManager, "on_civilian_died", "clientsidestealth_register_civilian_corpse", after_death)
	Hooks:PreHook(EnemyManager, "on_enemy_destroyed", "clientsidestealth_unregister_corpse", function(_, enemy)
		corpse.destroyed(enemy)
	end)
	Hooks:PreHook(
		EnemyManager,
		"on_civilian_destroyed",
		"clientsidestealth_unregister_civilian_target",
		function(_, unit)
			corpse.destroyed(unit)
		end
	)
	Hooks:PreHook(EnemyManager, "remove_corpse_by_id", "clientsidestealth_unregister_corpse_by_id", function(_, id)
		corpse.removed(id)
	end)
end

return M
