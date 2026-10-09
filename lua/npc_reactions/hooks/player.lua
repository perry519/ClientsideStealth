local reactions, restoring_call = ...
local M = {}

local scope, enemy_candidates

function M:install_player()
	if self._player_installed then
		return
	end
	self._player_installed = true
	local original_cool = CopMovement.cool
	local original_tweak = CopBase.char_tweak
	local original_enemies = EnemyManager.all_enemies
	local original_action = PlayerStandard._get_unit_intimidation_action
	local readers = {}
	local selectors = {}
	local function add_reader(fn, group)
		if group[fn] then
			return
		end
		group[fn] = true
		readers[fn] = true

		local index = 1
		while true do
			local name, value = debug.getupvalue(fn, index)
			if not name then
				break
			end
			if type(value) == "function" and name:find("intimidation_action", 1, true) then
				add_reader(value, group)
			end
			index = index + 1
		end
	end
	add_reader(original_action, selectors)
	add_reader(PlayerStandard._get_intimidation_action, readers)
	function EnemyManager:all_enemies(...)
		local caller = enemy_candidates and debug.getinfo(2, "f")
		if caller and selectors[caller.func] then
			return enemy_candidates
		end
		return original_enemies(self, ...)
	end
	function CopMovement:cool(...)
		local caller = scope and debug.getinfo(2, "f")
		if caller and readers[caller.func] and scope[self._unit] then
			return false
		end
		return original_cool(self, ...)
	end
	function CopBase:char_tweak(...)
		local caller = scope and debug.getinfo(2, "f")
		if caller and readers[caller.func] and scope[self._unit] then
			return scope[self._unit]
		end
		return original_tweak(self, ...)
	end
	function PlayerStandard:_get_unit_intimidation_action(
		enemies,
		civilians,
		teammates,
		only_special,
		escorts,
		amount,
		primary_only,
		detect_only,
		secondary
	)
		local previous, previous_candidates = scope, enemy_candidates
		scope, enemy_candidates = nil, nil
		local function invoke()
			local state = self._unit:movement():current_state_name()
			if
				not detect_only
				and not only_special
				and not secondary
				and (state == "standard" or state == "bleed_out")
				and (enemies or civilians)
			then
				scope, enemy_candidates = reactions.alerted_units(enemies, civilians)
			end
			return original_action(
				self,
				enemies,
				civilians,
				teammates,
				only_special,
				escorts,
				amount,
				primary_only,
				detect_only,
				secondary
			)
		end
		return restoring_call(function()
			scope, enemy_candidates = previous, previous_candidates
		end, invoke)
	end
end

function M:install()
	if self._installed then
		return
	end
	self._installed = true

	Hooks:PostHook(PlayerStandard, "init", "CSTNPCReactionsInit", function()
		self:install_player()
	end)
end

return M
