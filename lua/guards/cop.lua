local get_runtime, adapters, npc = ...
local M = {}
local runtime
local world_observations = setmetatable({}, { __mode = "k" })

function M.synchronize_dart_recovery(self, params)
	if params.act ~= "distraction_dazed" or not runtime:is_active() then
		return
	end
	local objective = self._logic_data.objective
	local followup = objective
		and objective.distraction
		and objective.action
		and objective.action.variant == "distraction_dazed"
		and objective.followup_objective
	local action = followup and followup.action
	if action and action.type == "idle" and action.body_part == 1 then
		action.sync = true
	end
end

local function observer_id(self)
	local id = self._unit:id()

	return id ~= -1 and id or nil
end

function M.create_attention_entry(data, unit, key, t)
	local attention = managers.groupai:state():get_AI_attention_objects_by_filter(data.SO_access_str, data.team)[key]
	local settings = attention and attention.handler:get_attention(data.SO_access, nil, nil, data.team)
	if not settings then
		return nil
	end
	local entry = CopLogicBase._create_detected_attention_object_data(t, unit, key, attention, settings)
	data.detected_attention_objects[key] = entry
	return entry
end

local function attention_entry(self, target)
	local data = self._logic_data

	if not data or not data.detected_attention_objects then
		return
	end

	local key = target:key()
	local entry = data.detected_attention_objects[key]

	if entry then
		entry._cst_remote = true
		return entry, data, key
	end

	entry = M.create_attention_entry(data, self._unit, key, data.t)

	if not entry then
		return
	end

	entry._cst_remote = true

	return entry, data, key
end

local function forget_entry(data, entry)
	CopLogicBase._destroy_detected_attention_object_data(data, entry)

	if data.attention_obj and data.attention_obj.u_key == entry.u_key then
		CopLogicBase._set_attention_obj(data, nil, nil)
	end
end

local function apply_transition(observer, target, report)
	local brain = observer:brain()
	local entry, data, key

	if brain then
		entry, data, key = attention_entry(brain, target)
	end

	if not entry then
		return false
	end

	if report.transition == "notice" then
		entry.notice_progress = report.value
		entry.prev_notice_chk_t = data.t

		if data.cool and entry.settings.reaction >= AIAttentionObject.REACT_SCARED then
			managers.groupai:state():on_criminal_suspicion_progress(target, observer, report.value)
		end

		if entry.settings.notice_clbk then
			entry.settings.notice_clbk(observer, report.value)
		end
	elseif report.transition == "verified" then
		entry.verified = report.value == 1

		if entry.verified then
			mvector3.set(entry.verified_pos, entry.m_head_pos)
			entry.verified_dis = mvector3.distance(observer:movement():m_head_pos(), entry.m_head_pos)
		end
	elseif report.transition == "identified" then
		entry.identified = true
		entry.identified_t = TimerManager:game():time()
		entry.notice_progress = nil
		entry.prev_notice_chk_t = nil
		data.logic.on_attention_obj_identified(data, key, entry)

		if entry.settings.notice_clbk then
			entry.settings.notice_clbk(observer, true)
		end
		local internal = data.internal_data
		local task = internal and (internal.detection_task_key or internal.upd_task_key)
		if task and internal.queued_tasks and internal.queued_tasks[task] then
			if data.cool and entry.settings.reaction >= AIAttentionObject.REACT_SCARED then
				for index, queued in ipairs(managers.enemy._queued_tasks or {}) do
					if queued.id == task and queued.data == data then
						managers.enemy:_execute_queued_task(index)
						return true
					end
				end
			end
			managers.enemy:update_queue_task(task, nil, nil, TimerManager:game():time(), nil, true)
		end
	elseif report.transition == "suspicion" then
		local masked_exposure = report.target_kind == "player"
			and report.value >= 1
			and entry.settings.reaction >= AIAttentionObject.REACT_SCARED
		if entry.settings.reaction ~= AIAttentionObject.REACT_SUSPICIOUS and not masked_exposure then
			return false
		end
		entry.uncover_progress = report.value > 0 and report.value or nil
		entry.last_suspicion_t = entry.uncover_progress and TimerManager:game():time() or nil
		local status = report.value >= 1 and true or report.value > 0 and report.value or false
		target:movement():on_suspicion(observer, status)
		managers.groupai:state():on_criminal_suspicion_progress(target, observer, status)
		if report.value >= 1 and not entry._cst_uncovered then
			entry._cst_uncovered = true
			local internal = data.internal_data
			managers.groupai:state():criminal_spotted(target)
			target:movement():on_uncovered(observer)
			local arrest = entry.dis < 2000 and entry.verified and not data.char_tweak.no_arrest and not entry.forced
			entry.reaction = arrest and AIAttentionObject.REACT_ARREST or AIAttentionObject.REACT_COMBAT

			CopLogicBase._set_attention_obj(data, entry, entry.reaction)
			local allow, failed = CopLogicBase.is_obstructed(data, data.objective, nil, entry)
			if allow then
				if failed then
					data.objective_failed_clbk(observer, data.objective)
				end
				if internal == data.internal_data then
					CopLogicBase._exit(observer, arrest and "arrest" or "attack")
				end
			end
		end
	elseif report.transition == "lost" then
		forget_entry(data, entry)
	end

	return true
end

local function record_host_observations(data)
	local previous = world_observations[data] or {}
	local current = {}
	local id

	for key, entry in pairs(data.detected_attention_objects or {}) do
		local target = runtime:target_for_unit(entry.unit)

		if target then
			id = id or data.unit:id()
			local state = {
				identified = entry.identified == true,
				notice = entry.notice_progress,
				verified = entry.verified == true,
				target = target,
			}
			local old = previous[key] or {}

			current[key] = state
			if not old.target and state.notice == nil and state.identified then
				runtime:record_world_observation("guard", id, target.kind, target.id, "notice", 1)
			end
			if state.notice ~= nil and state.notice ~= old.notice then
				runtime:record_world_observation("guard", id, target.kind, target.id, "notice", state.notice)
			end
			if state.verified ~= old.verified then
				runtime:record_world_observation(
					"guard",
					id,
					target.kind,
					target.id,
					"verified",
					state.verified and 1 or 0
				)
			end
			if state.identified and not old.identified then
				runtime:record_world_observation("guard", id, target.kind, target.id, "identified", 1)
			end
		end
	end

	for key, old in pairs(previous) do
		if not current[key] then
			id = id or data.unit:id()
			runtime:record_world_observation("guard", id, old.target.kind, old.target.id, "lost", 0)
		end
	end

	world_observations[data] = current
end

local function entry_owner(entry)
	local target = runtime:target_for_unit(entry.unit)
	return target and runtime:target_owner(target.kind, target.id)
end

function M.delegated(entry)
	if not runtime:is_active() then
		return false
	end

	local owner = entry_owner(entry)
	return owner ~= nil and owner ~= runtime.local_peer_id
end

function M.hold_delegated_suspicion(data)
	for _, entry in pairs(data.detected_attention_objects) do
		if entry.uncover_progress and M.delegated(entry) then
			entry.last_suspicion_t = data.t
		end
	end
end

function M.refresh_remote_attention(data)
	if not Network:is_server() or not runtime:is_active() then
		return
	end
	record_host_observations(data)
	for _, entry in pairs(data.detected_attention_objects or {}) do
		if entry._cst_remote and entry_owner(entry) == runtime.local_peer_id then
			entry._cst_remote = nil
		end
		if entry._cst_remote then
			entry.dis = mvector3.distance(data.m_pos, entry.m_pos)
			if entry.verified then
				entry.verified_t = data.t
				entry.verified_dis = entry.dis
				mvector3.set(entry.verified_pos, entry.m_head_pos)
				entry.last_verified_pos = mvector3.copy(entry.m_head_pos)
			end
		end
	end
end

function M.cool_changed(self, cool)
	local id = observer_id(self)
	if id and Network:is_server() and self._cst_snapshot_cool ~= cool then
		self._cst_snapshot_cool = cool
		runtime:guard_cool_changed(id)
	end
end

function M.register_brain(self)
	npc.bind(self._unit)
	local id = observer_id(self)

	if id then
		runtime:register_observer("guard", id, self._unit, self)
	end
end

function M.unregister_brain(self)
	npc.unbind(self._unit)
	local id = observer_id(self)

	if id then
		runtime:unregister_observer("guard", id)
	end
end

function M.release_npc(self)
	npc.unbind(self._unit)
end

function M.start()
	runtime = get_runtime()
	adapters:register("guard", {
		apply_transition = apply_transition,
		clear_host_observations = function()
			world_observations = setmetatable({}, { __mode = "k" })
		end,
		cleanup_observer = function(observer, target)
			local brain = observer:brain()
			local data = brain and brain._logic_data
			local entry = data and data.detected_attention_objects and data.detected_attention_objects[target:key()]
			if entry then
				forget_entry(data, entry)
			end
		end,
	})
end

return M
