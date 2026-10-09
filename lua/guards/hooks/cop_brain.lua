local cop = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	cop.start()
	Hooks:PostHook(
		CopBrain,
		"set_distract_objective",
		"ClientsideStealthSyncDartRecovery",
		cop.synchronize_dart_recovery
	)
	local original_suspicion = CopLogicBase._upd_suspicion
	CopLogicBase._upd_suspicion = function(data, internal, entry, ...)
		if cop.delegated(entry) then
			return
		end
		return original_suspicion(data, internal, entry, ...)
	end
	local original_decay = CopLogicBase.upd_suspicion_decay
	CopLogicBase.upd_suspicion_decay = function(data, ...)
		cop.hold_delegated_suspicion(data)
		return original_decay(data, ...)
	end
	Hooks:PostHook(
		CopLogicBase,
		"_upd_attention_obj_detection",
		"ClientsideStealthRefreshRemoteAttention",
		function(data)
			local delay = Hooks:GetReturn()
			cop.refresh_remote_attention(data)
			return delay
		end
	)
	Hooks:PostHook(CopBrain, "on_cool_state_changed", "ClientsideStealthGuardCoolSnapshot", cop.cool_changed)
	Hooks:PostHook(CopBrain, "post_init", "ClientsideStealthRegisterCopBrain", cop.register_brain)
	Hooks:PreHook(CopBrain, "pre_destroy", "ClientsideStealthUnregisterCopBrain", cop.unregister_brain)
	Hooks:PostHook(CopBrain, "on_tied", "ClientsideStealthClearTiedNPC", function(brain, _, not_tied)
		if not not_tied and brain._logic_data and brain._logic_data.is_tied then
			cop.release_npc(brain)
		end
	end)
	Hooks:PostHook(CopBrain, "convert_to_criminal", "ClientsideStealthClearConvertedNPC", cop.release_npc)
end

return M
