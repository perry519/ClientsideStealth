local assets = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PostHook(DynamicResourceManager, "init", "ClientsideStealthLoadAssets", assets.load)
end

return M
