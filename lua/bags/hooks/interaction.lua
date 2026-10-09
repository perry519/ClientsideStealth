local host, client, retained, preview = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	local interact = Hooks:GetFunction(CarryInteractionExt, "interact")
	local sync_interacted = Hooks:GetFunction(CarryInteractionExt, "sync_interacted")
	local corpse_interact = Hooks:GetFunction(IntimitateInteractionExt, "interact")

	Hooks:OverrideFunction(CarryInteractionExt, "interact", function(interaction, player, ...)
		preview:prepare_pickup(interaction._unit)
		local tracked, native_pickup = client:interaction_started(interaction._unit)
		local result = interact(interaction, player, ...)
		if tracked then
			client:interaction_finished(interaction._unit, native_pickup, result)
		end
		return result
	end)

	Hooks:OverrideFunction(IntimitateInteractionExt, "interact", function(interaction, player, ...)
		local predicting = interaction.tweak_data == "corpse_dispose"
			and client:corpse_pickup_started(interaction._unit)
		local result = corpse_interact(interaction, player, ...)
		if predicting then
			client:corpse_pickup_finished()
		end
		return result
	end)

	Hooks:OverrideFunction(CarryInteractionExt, "sync_interacted", function(interaction, peer, player, ...)
		if not retained.enabled() then
			return sync_interacted(interaction, peer, player, ...)
		end
		if Network:is_server() then
			if peer and interaction._remove_on_interact and host:can_retain(peer, interaction._unit) then
				return host:retain_pickup(interaction, peer, player)
			end
			return sync_interacted(interaction, peer, player, ...)
		end
		if client:observe_retained_pickup(interaction, peer, player) then
			return
		end
		local tracked = interaction._remove_on_interact
		if tracked then
			client:begin_observer_pickup(interaction._unit, peer and peer:id())
		end
		local result = sync_interacted(interaction, peer, player, ...)
		if tracked then
			client:finish_observer_pickup(interaction._unit)
		end
		return result
	end)
end

return M
