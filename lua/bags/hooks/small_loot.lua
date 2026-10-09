local client = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PostHook(SmallLootBase, "take", "clientsidestealth_hide_taken_small_loot", function(base)
		client:small_loot_taken(base)
	end)
end

return M
