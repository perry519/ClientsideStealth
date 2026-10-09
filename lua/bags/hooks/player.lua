local bag_lifecycle, client, bag_preview, retained = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	local original = {
		drop = Hooks:GetFunction(PlayerManager, "drop_carry"),
		force_drop = Hooks:GetFunction(PlayerManager, "force_drop_carry"),
		server_drop = Hooks:GetFunction(PlayerManager, "server_drop_carry"),
		can_carry = Hooks:GetFunction(PlayerManager, "can_carry"),
	}
	Hooks:OverrideFunction(PlayerManager, "can_carry", function(self, ...)
		return (not retained.enabled() or not client:pickup_pending()) and original.can_carry(self, ...)
	end)

	local function drop(self, zipline, forced)
		local data = self:get_my_carry_data()
		local player = self:player_unit()
		if not data or not alive(player) then
			return false
		end
		local camera = player:camera()
		local position, rotation, direction = camera:position(), camera:rotation(), camera:forward()
		local upgrade = managers.player:upgrade_level("carry", "throw_distance_multiplier", 0)
		if forced then
			direction, upgrade = Vector3(0, 0, 0), 0
		elseif _G.IS_VR then
			local hand = player:hand():get_active_hand("bag")
			if hand then
				position, rotation = hand:position(), hand:rotation()
				direction = rotation:y()
			end
		end
		local outcome = bag_lifecycle:drop(data, position, rotation, direction, upgrade, zipline)
		if outcome ~= "dropped" then
			return outcome == "pending"
		end
		if not forced then
			self._carry_blocked_cooldown_t = Application:time() + 1.2 + math.rand(0.3)
			player:sound():play("Play_bag_generic_throw", nil, false)
		end
		managers.hud:remove_teammate_carry_info(HUDManager.PLAYER_PANEL)
		managers.hud:temp_hide_carry_bag()
		self:update_removed_synced_carry_to_peers()
		if not forced and self._current_state == "carry" then
			self:set_player_state("standard")
		end
		return true
	end

	Hooks:OverrideFunction(PlayerManager, "drop_carry", function(self, zipline)
		if not client:can_finish_drop(self:get_my_carry_data()) then
			return original.drop(self, zipline)
		end
		if not drop(self, zipline, false) then
			return original.drop(self, zipline)
		end
	end)
	Hooks:PostHook(
		PlayerManager,
		"sync_carry_data",
		"ClientsideStealthBagPreview",
		function(_, unit, carry_id, _, _, _, _, position, _, _, _, peer_id)
			bag_preview:reconcile(unit, carry_id, position, peer_id)
		end
	)
	Hooks:OverrideFunction(PlayerManager, "force_drop_carry", function(self)
		if not client:can_finish_drop(self:get_my_carry_data()) then
			return original.force_drop(self)
		end
		if not drop(self, nil, true) then
			return original.force_drop(self)
		end
	end)
	Hooks:OverrideFunction(PlayerManager, "server_drop_carry", function(manager, ...)
		if not retained.enabled() then
			return original.server_drop(manager, ...)
		end
		return bag_lifecycle:host_drop(manager, { ... }, original.server_drop, ...)
	end)
	for _, method in ipairs({ "bank_carry", "clear_carry" }) do
		Hooks:PreHook(PlayerManager, method, "ClientsideStealthBag" .. method, function()
			if not Network:is_server() then
				client:clear_local()
			end
		end)
	end
end

return M
