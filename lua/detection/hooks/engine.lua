local native_ai, restoring_call = ...
local ecm_hooked, groupai_hooked, groupai_indexed_hooked, suspicion_hooked, coplogic_hooked, civilianlogic_hooked

local function camera_jammed(state)
	return state:is_ecm_jammer_active("camera") and true or false
end

local function routed_send(session, observer, owner, delivered)
	local send = session.send_to_peers_synched
	return function(s, message, unit, code, ...)
		if message == "suspicion_hud" and unit == observer and (code == 0 or code == 1) then
			if owner then
				return s:send_to_peers_synched_except(owner, message, unit, code, ...)
			end
			for peer_id, peer in pairs(s:peers()) do
				if not delivered[peer_id] then
					peer:send_queued_sync(message, unit, code, ...)
				end
			end
			return
		end
		return send(s, message, unit, code, ...)
	end
end

local function install_groupai()
	if GroupAIStateBase.register_ecm_jammer and not ecm_hooked then
		ecm_hooked = true
		local original = GroupAIStateBase.register_ecm_jammer
		function GroupAIStateBase:register_ecm_jammer(...)
			local was_jammed = camera_jammed(self)
			local result = original(self, ...)
			if was_jammed ~= camera_jammed(self) then
				native_ai.camera_jamming_changed()
			end
			return result
		end
	end

	if not groupai_hooked then
		groupai_hooked = true
		local original = GroupAIStateBase.get_AI_attention_objects_by_filter
		function GroupAIStateBase:get_AI_attention_objects_by_filter(...)
			return native_ai.filter_attention(original(self, ...))
		end
	end

	if GroupAIStateBase.get_AI_attention_objects_by_filter_i and not groupai_indexed_hooked then
		groupai_indexed_hooked = true
		local original = GroupAIStateBase.get_AI_attention_objects_by_filter_i
		function GroupAIStateBase:get_AI_attention_objects_by_filter_i(...)
			return native_ai.filter_indexed_attention(original(self, ...))
		end
	end

	if GroupAIStateBase.on_criminal_suspicion_progress and not suspicion_hooked then
		suspicion_hooked = true
		local original = GroupAIStateBase.on_criminal_suspicion_progress
		function GroupAIStateBase:on_criminal_suspicion_progress(suspect, observer, status)
			if native_ai.suppress_suspicion(self, suspect, observer, status) then
				return
			end
			local owner, delivered = native_ai.suspicion_routing(self, suspect, observer, status)
			local session = (owner or delivered) and managers.network:session()
			if not session then
				return original(self, suspect, observer, status)
			end

			local saved = rawget(session, "send_to_peers_synched")
			session.send_to_peers_synched = routed_send(session, observer, owner, delivered)
			return restoring_call(function()
				session.send_to_peers_synched = saved
			end, original, self, suspect, observer, status)
		end
	end
end

local function install_coplogic()
	if coplogic_hooked then
		return
	end
	coplogic_hooked = true
	local original = CopLogicBase._upd_attention_obj_detection
	function CopLogicBase._upd_attention_obj_detection(data, ...)
		if not native_ai.scopes_guard(data) then
			return original(data, ...)
		end
		return native_ai.detect_guard(data, original, ...)
	end
end

local function install_civilianlogic()
	if civilianlogic_hooked then
		return
	end
	civilianlogic_hooked = true
	local original = CivilianLogicIdle._get_priority_attention
	function CivilianLogicIdle._get_priority_attention(data, ...)
		local best, reaction = original(data, ...)
		return native_ai.civilian_priority(data, best, reaction)
	end
end

local function install(hook_target)
	assert(
		hook_target == "groupai" or hook_target == "coplogic" or hook_target == "civilianlogic",
		"ClientsideStealth: invalid engine hook target"
	)
	if hook_target == "groupai" and GroupAIStateBase then
		install_groupai()
	elseif hook_target == "coplogic" and CopLogicBase then
		install_coplogic()
	elseif hook_target == "civilianlogic" and CivilianLogicIdle then
		install_civilianlogic()
	end
end

return install
