local dart, surrender_action = ...
local M = {}

function M:install_movement()
	if self._movement_installed then
		return
	end
	self._movement_installed = true
	local original_request = CopMovement.action_request
	CopMovement.action_request = function(movement, descriptor)
		dart.before_request(movement, descriptor)
		local action = original_request(movement, descriptor)
		dart.after_request(movement)
		return action
	end
	local original_redirect = CopMovement.play_redirect
	CopMovement.play_redirect = function(movement, redirect, ...)
		if redirect == "equip" and surrender_action.blocks_equip(movement) then
			return
		end
		return original_redirect(movement, redirect, ...)
	end
	local original_start = CopMovement.sync_action_act_start
	CopMovement.sync_action_act_start = function(movement, ...)
		if dart.act_started(movement, ...) or surrender_action.act_started(movement, ...) then
			return
		end
		return original_start(movement, ...)
	end
	local original_end = CopMovement.sync_action_act_end
	CopMovement.sync_action_act_end = function(movement, body_part)
		local replaced, owned = dart.act_ending(movement, body_part)
		if replaced then
			return
		end
		local result
		if not surrender_action.act_ending(movement, body_part) then
			result = original_end(movement, body_part)
		end
		if owned then
			dart.act_ended(movement._unit)
		end
		return result
	end
end

function M:install_husk_movement()
	if self._husk_installed then
		return
	end
	self._husk_installed = true
	local original = HuskCopMovement.action_request
	HuskCopMovement.action_request = function(movement, descriptor)
		dart.before_request(movement, descriptor)
		surrender_action.before_request(movement, descriptor)
		local action = original(movement, descriptor)
		dart.after_request(movement)
		return action
	end
end

return M
