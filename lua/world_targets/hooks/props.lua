local props = ...
local M = {}

function M:install_interaction(class)
	if self._interaction_installed then
		return
	end
	self._interaction_installed = true
	local interact = class.interact
	function class:interact(player, ...)
		local result = interact(self, player, ...)
		if result then
			props.interacted(self._unit, player)
		end
		return result
	end
	local sync_interacted = class.sync_interacted
	function class:sync_interacted(...)
		local player = sync_interacted(self, ...)
		if alive(player) then
			props.interacted(self._unit, player)
		end
		return player
	end
end

function M:install_sequence(class)
	if self._sequence_installed then
		return
	end
	self._sequence_installed = true
	Hooks:PostHook(class, "activate_callback", "clientsidestealth_prop_attention", function(_, env)
		props.sequence_attention(env)
	end)
end

function M:install_attention(class)
	if self._attention_installed then
		return
	end
	self._attention_installed = true
	Hooks:PostHook(class, "_call_listeners", "clientsidestealth_prop_attention_removed", props.attention_changed)
	Hooks:PreHook(class, "destroy", "clientsidestealth_prop_destroy", props.destroy)
end

return M
