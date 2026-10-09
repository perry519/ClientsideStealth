local host, client, requests, retained, from_host = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	self:install_outgoing()
	local original = {
		rethrow = Hooks:GetFunction(UnitNetworkHandler, "sync_carry_set_position_and_throw"),
		link = Hooks:GetFunction(UnitNetworkHandler, "loot_link"),
		interaction = Hooks:GetFunction(UnitNetworkHandler, "interaction_set_active"),
		reply = Hooks:GetFunction(UnitNetworkHandler, "carry_interaction_reply"),
		pickup_request = Hooks:GetFunction(UnitNetworkHandler, "sync_carry_interacted"),
		server_drop = Hooks:GetFunction(UnitNetworkHandler, "server_drop_carry"),
	}
	Hooks:OverrideFunction(UnitNetworkHandler, "server_drop_carry", function(self, ...)
		local args = { ... }
		local sender = args[11]
		local peer = Network:is_server() and self._verify_sender(sender)
		if not peer then
			return original.server_drop(self, ...)
		end
		return requests:with_drop_request(peer:id(), original.server_drop, self, ...)
	end)
	Hooks:OverrideFunction(
		UnitNetworkHandler,
		"sync_carry_interacted",
		function(self, unit, unit_id, tweak_id, carry_id, sender)
			if Network:is_server() and retained.enabled() then
				local peer = self._verify_sender(sender)
				if peer and self._verify_gamestate(self._gamestate_filter.any_ingame) then
					host:observe_pickup_request(peer, unit, unit_id, tweak_id, carry_id)
				end
			end
			return original.pickup_request(self, unit, unit_id, tweak_id, carry_id, sender)
		end
	)
	Hooks:OverrideFunction(
		UnitNetworkHandler,
		"interaction_set_active",
		function(self, unit, u_id, active, tweak_data, flash, sender)
			if
				active
				and tweak_data == "corpse_dispose"
				and from_host(self, sender)
				and requests:keep_corpse_hidden(unit, u_id)
			then
				return
			end
			if
				retained.enabled()
				and not active
				and alive(unit)
				and from_host(self, sender)
				and client:skip_interaction(unit)
			then
				return
			end
			return original.interaction(self, unit, u_id, active, tweak_data, flash, sender)
		end
	)
	Hooks:OverrideFunction(UnitNetworkHandler, "loot_link", function(self, unit, parent, sender)
		if
			retained.enabled()
			and alive(unit)
			and alive(parent)
			and from_host(self, sender)
			and client:skip_link(unit, parent)
		then
			return
		end
		return original.link(self, unit, parent, sender)
	end)
	Hooks:OverrideFunction(
		UnitNetworkHandler,
		"sync_carry_set_position_and_throw",
		function(self, unit, destination, direction, force, sender)
			if
				retained.enabled()
				and alive(unit)
				and from_host(self, sender)
				and client:skip_rethrow(unit, destination, direction, force)
			then
				return
			end
			return original.rethrow(self, unit, destination, direction, force, sender)
		end
	)
	Hooks:OverrideFunction(UnitNetworkHandler, "carry_interaction_reply", function(self, status, carry_id)
		if retained.enabled() and self._verify_gamestate(self._gamestate_filter.any_ingame) then
			local _, suppress_native = client:reply(status, carry_id)
			if suppress_native then
				return
			end
		end
		return original.reply(self, status, carry_id)
	end)
	Hooks:PostHook(
		UnitNetworkHandler,
		"remove_corpse_by_id",
		"clientsidestealth_bodybag_remove_reply",
		function(self, corpse_id, carry_bodybag, peer_id, sender)
			local current = managers.network and managers.network:session()
			local local_peer = current and current:local_peer()
			if carry_bodybag == true and local_peer and peer_id == local_peer:id() and from_host(self, sender) then
				requests:approve_corpse(corpse_id)
			end
		end
	)
end

function M:install_outgoing()
	if self._outgoing_installed then
		return
	end
	self._outgoing_installed = true
	Hooks:PreHook(
		ClientNetworkSession,
		"send_to_host",
		"clientsidestealth_bag_native_send",
		function(network, method, carry_id)
			if method == "server_drop_carry" then
				requests:outgoing_drop(network, carry_id)
			end
		end
	)
end

return M
