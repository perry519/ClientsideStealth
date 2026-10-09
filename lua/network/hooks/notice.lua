local transport = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:Add("MenuManagerOnOpenMenu", "ClientsideStealthRpcRestartNotice", function()
		if not transport.restart_required or Global.cst_rpc_notice_shown then
			return
		end
		Global.cst_rpc_notice_shown = true
		local loc = managers.localization
		QuickMenu:new(loc:text("cst_rpc_restart_title"), loc:text("cst_rpc_restart_desc"), {}, true)
	end)
end

return M
