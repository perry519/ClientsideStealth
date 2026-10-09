local suspicion = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	suspicion.start()
	local original_notice = Hooks:GetFunction(PlayerMovement, "clbk_attention_notice_sneak")
	local original_on_suspicion = Hooks:GetFunction(PlayerMovement, "on_suspicion")
	Hooks:OverrideFunction(PlayerMovement, "clbk_attention_notice_sneak", function(movement, observer_unit, status)
		if not suspicion.consume_local_notice(movement, observer_unit, status) then
			return original_notice(movement, observer_unit, status)
		end
		if alive(observer_unit) and not suspicion.ignores_notice(movement, observer_unit) then
			suspicion.show_local(movement, observer_unit, status)
		end
	end)
	Hooks:OverrideFunction(PlayerMovement, "on_suspicion", function(movement, observer_unit, status)
		if suspicion.replaces_native(movement, observer_unit) then
			return
		end
		return original_on_suspicion(movement, observer_unit, status)
	end)
end

return M
