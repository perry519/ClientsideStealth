local surrender, surrender_host = ...
local M = {}
function M:install_host()
	if self._host_installed then
		return
	end
	self._host_installed = true
	Hooks:PostHook(CopBrain, "on_intimidated", "CSTSurrenderResult", function(self, amount, aggressor)
		surrender_host.on_intimidated(self, amount, aggressor)
	end)
end

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PostHook(HuskCopBrain, "on_intimidated", "CSTSurrenderPrediction", function(self, amount, aggressor)
		surrender.begin(self._unit, amount, aggressor)
	end)
	Hooks:PostHook(HuskCopBrain, "sync_surrender", "CSTSurrenderPredictionSync", function(self)
		surrender.sync(self._unit, self._surrendered == true)
	end)
end
return M
