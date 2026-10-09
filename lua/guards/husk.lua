local world_target, get_runtime, adapters, npc, dart_prediction, features, reports, create_attention_entry = ...
local M = {}

local runtime
local brains = {}
local importance = {}
local logic = {}

local function surrender_pending(unit)
	local adapter = adapters.npc
	return adapter and adapter.surrender_pending and adapter.surrender_pending(unit) or false
end

local function refresh_importance()
	for _, brain in pairs(brains) do
		local important = false
		for _, ranked in pairs(importance) do
			for _, entry in ipairs(ranked) do
				if entry.brain == brain then
					important = true
					break
				end
			end
			if important then
				break
			end
		end
		brain:set_important(important)
	end
end

local function remove_importance(self)
	if not self._important then
		return
	end
	for key, ranked in pairs(importance) do
		for index = #ranked, 1, -1 do
			if ranked[index].brain == self then
				table.remove(ranked, index)
			end
		end
		if #ranked == 0 then
			importance[key] = nil
		end
	end
	self:set_important(false)
end

function M.set_important(self, state)
	if state and not self._important then
		self._cst_next_detection_t = 0
	end
	self._important = state
	if self._cst_detection_data then
		self._cst_detection_data.important = state
	end
end

local function show_local_alert(unit, source_unit)
	local state = managers.groupai:state()
	local key = unit:key()
	local hud = state._suspicion_hud_data[key]
	if not (hud and hud.alerted) then
		state:on_criminal_suspicion_progress(source_unit, unit, true)
		hud = state._suspicion_hud_data[key]
		if hud and hud.alerted then
			hud._cst_local_alert_target = source_unit
		end
	end
end

function logic.on_attention_obj_identified(data, _, entry)
	if data.cool and entry.settings.reaction >= AIAttentionObject.REACT_SCARED then
		show_local_alert(data.unit, entry.unit)
		if not surrender_pending(entry.unit) then
			npc.predict(data.unit, entry.unit, "npc_alert", "guard", data.unit:id())
		end
	end
end

function logic._chk_nearly_visible_chk_needed()
	return false
end

local function eligible(self, active)
	return active
		and not self._dead
		and not self._surrendered
		and not self._converted
		and not self._unit:in_slot(16)
		and not surrender_pending(self._unit)
end

local function clear_unit_alert(unit, target)
	local state = managers.groupai:state()
	local key = unit:key()
	local hud = state._suspicion_hud_data[key]
	if hud and hud._cst_local_alert_target and (not target or hud._cst_local_alert_target == target) then
		if target and (not unit:movement():cool() or runtime:current_npc_alert(unit)) then
			return
		end
		state:_clear_character_criminal_suspicion_data(key)
	end
end

local function clear_local_alert(self, target)
	clear_unit_alert(self._unit, target)
end

local function clear(self)
	remove_importance(self)
	local data = self._cst_detection_data

	if data and next(data.detected_attention_objects) then
		CopLogicBase._destroy_all_detected_attention_object_data(data)
	end

	reports.clear(self)
end

local function retire_dart(self)
	dart_prediction:retire(self._unit)
end

local function setup_detection(self)
	local id = self._unit:id()

	if id == -1 then
		return
	end

	local character = tweak_data.character[self._unit:base()._tweak_table]

	if not character or not character.detection or not character.detection.ntl then
		return
	end

	self._cst_detection_data = {
		_cst_client_detection = true,
		char_tweak = character,
		SO_access = managers.navigation:convert_access_flag(character.access),
		SO_access_str = character.access,
		cool = true,
		detected_attention_objects = {},
		enemy_slotmask = managers.slot:get_mask("criminals"),
		internal_data = {
			detection = character.detection.ntl,
		},
		key = self._unit:key(),
		logic = logic,
		m_pos = self._unit:movement():m_pos(),
		team = self._unit:movement():team(),
		unit = self._unit,
		visibility_slotmask = managers.slot:get_mask("AI_visibility"),
	}
	if _G.FullSpeedSwarm then
		local data = self._cst_detection_data
		data.detected_attention_objects_i = _G.FullSpeedSwarm.metaize_i(data.detected_attention_objects)
		data.fs_ext_movement = self._unit:movement()
	end
	reports.setup(self)
	self._cst_next_detection_t = 0
	self._cst_observer_id = id
	brains[id] = self

	runtime:register_observer("guard", id, self._unit, self)
end

function M.setup(self)
	setup_detection(self)
	npc.bind(self._unit)
end

local function casing_local_player(entry)
	local target = runtime:target_for_unit(entry.unit)
	local movement = target and target.kind == "player" and target.id == runtime.local_peer_id and entry.unit:movement()
	local state = movement and movement:current_state_name()
	return state == "mask_off" or state == "clean" or state == "civilian"
end

local function reset_uncover(entry)
	entry.uncover_progress = 0
	entry.last_suspicion_t = nil
end

local function advance_uncover(data, entry)
	local settings = entry.settings
	local suspicion = entry.unit:base():suspicion_settings()
	local distance = entry.dis
	local suspicion_range = settings.suspicion_range
	if
		entry.verified
		and settings.uncover_range
		and distance < math.min(settings.max_range, settings.uncover_range) * suspicion.range_mul
	then
		entry.uncover_progress = 1
		entry._cst_uncovered = true
	elseif
		entry.verified
		and suspicion_range
		and distance < math.min(settings.max_range, suspicion_range) * suspicion.range_mul
	then
		if entry.last_suspicion_t then
			local uncover_range = (settings.uncover_range or 0) * suspicion.range_mul
			local range_max = (suspicion_range - (settings.uncover_range or 0)) * suspicion.range_mul
			local multiplier = range_max > 0 and 1 - (distance - uncover_range) / range_max or 1
			if data.internal_data.detection.suspicion_mul then
				multiplier = multiplier * data.internal_data.detection.suspicion_mul
			end
			local increment = (data.t - entry.last_suspicion_t)
				* multiplier
				* suspicion.buildup_mul
				/ settings.suspicion_duration
			entry.uncover_progress = math.min(1, (entry.uncover_progress or 0) + increment)
			entry._cst_uncovered = entry.uncover_progress == 1
		else
			entry.uncover_progress = 0
		end
		entry.last_suspicion_t = data.t
	elseif entry.uncover_progress then
		entry.uncover_progress = math.max(0, entry.uncover_progress - (data.t - (entry.last_suspicion_t or data.t)))
		entry.last_suspicion_t = entry.uncover_progress > 0 and data.t or nil
	end
end

local function predict_uncovered(data, entry)
	show_local_alert(data.unit, entry.unit)
	npc.predict(data.unit, entry.unit, "player_alert", "guard", data.unit:id())
end

local function update_casing_suspicion(data)
	for _, entry in pairs(data.detected_attention_objects) do
		if not casing_local_player(entry) then
			if entry.uncover_progress then
				reset_uncover(entry)
			end
		elseif
			entry.identified
			and entry.reaction == AIAttentionObject.REACT_SUSPICIOUS
			and not entry._cst_uncovered
		then
			advance_uncover(data, entry)
			if entry._cst_uncovered then
				predict_uncovered(data, entry)
			end
		elseif entry.uncover_progress and not entry._cst_uncovered then
			reset_uncover(entry)
		end
	end
end

local function detection_profile(self, movement)
	local action, queued = movement:_get_latest_act_action(1)
	local descriptor = action and (queued and action or action._action_desc)
	local profiles = self._cst_detection_data.char_tweak.detection
	local pending = dart_prediction:pending(self._unit)
	return (pending or descriptor and descriptor.variant == "distraction_dazed") and profiles.dazed or profiles.ntl
end

local function wake_attention(data)
	for _, entry in pairs(data.detected_attention_objects) do
		entry.next_verify_t = 0
	end
end

local function update_detection(self, t, active, force)
	if not eligible(self, active) then
		retire_dart(self)

		if not surrender_pending(self._unit) then
			clear_local_alert(self)
		end
		clear(self)

		return
	end

	if not force and t < self._cst_next_detection_t then
		return
	end

	local movement = self._unit:movement()
	if not movement:cool() then
		retire_dart(self)
		clear(self)

		return
	end

	local alert = runtime:current_npc_alert(self._unit)
	if alert and alert.status ~= "local" then
		return
	end
	if reports.is_held(self, t) then
		return
	end

	local data = self._cst_detection_data

	data.internal_data.detection = detection_profile(self, movement)
	data.cool = true
	data.m_pos = movement:m_pos()
	data.t = t
	data.team = movement:team()

	local delay = CopLogicBase._upd_attention_obj_detection(data, AIAttentionObject.REACT_SUSPICIOUS)
	for _, entry in pairs(data.detected_attention_objects) do
		if entry.reaction and entry.reaction < AIAttentionObject.REACT_SUSPICIOUS then
			CopLogicBase._destroy_detected_attention_object_data(data, entry)
		end
	end
	update_casing_suspicion(data)
	if self._important then
		local fss = _G.FullSpeedSwarm
		local fss_changes = fss and (not fss.allow_stealth_changes or fss:allow_stealth_changes())
		delay = fss_changes and 0.1 or 0
	end
	self._cst_next_detection_t = t + delay
	reports.update(self, clear_local_alert)
end

local guard_adapter = {}
guard_adapter.touch_detection = function(unit, t)
	local brain = brains[unit:id()]
	if not brain or brain._unit ~= unit or not brain._cst_detection_data then
		return false
	end
	if runtime.enabled == false or not features.allows_detection() then
		return false
	end
	local active = runtime:is_active()
	if not eligible(brain, active) or not unit:movement():cool() then
		return false
	end
	wake_attention(brain._cst_detection_data)
	update_detection(brain, t or TimerManager:game():time(), active, true)
	brain._cst_next_detection_t = 0
	return true
end
guard_adapter.wake_detection = function(unit)
	local brain = brains[unit:id()]
	if brain and brain._unit == unit and brain._cst_detection_data then
		local data = brain._cst_detection_data
		data.internal_data.detection = detection_profile(brain, unit:movement())
		wake_attention(data)
		brain._cst_next_detection_t = 0
	end
end
guard_adapter.set_importance_weight = function(id, report)
	local brain = brains[id]
	if not brain or #report == 0 then
		return
	end
	local limit = managers.groupai:state()._nr_important_cops or 3
	local membership_changed = false
	for index = 1, #report - 1, 2 do
		local key, weight = report[index], report[index + 1]
		local ranked = importance[key] or {}
		importance[key] = ranked
		local entry
		for rank = #ranked, 1, -1 do
			if ranked[rank].brain == brain then
				entry = table.remove(ranked, rank)
				break
			end
		end
		local rank = #ranked + 1
		while rank > 1 and weight < ranked[rank - 1].weight do
			rank = rank - 1
		end
		if rank <= limit then
			membership_changed = membership_changed or entry == nil
			entry = entry or { brain = brain }
			entry.weight = weight
			table.insert(ranked, rank, entry)
			if #ranked > limit then
				table.remove(ranked)
			end
		elseif entry then
			membership_changed = true
		end
	end
	if membership_changed then
		refresh_importance()
	end
end
guard_adapter.show_local_alert = show_local_alert
guard_adapter.suspend_alert = function(unit)
	local state = managers.groupai:state()
	local key = unit:key()
	local hud = state._suspicion_hud_data[key]
	if not hud then
		return nil
	end
	local saved = {
		status = hud.status or hud.alerted and true,
		local_target = hud._cst_local_alert_target,
		expire_t = hud.expire_t,
		persistent = hud.persistent,
	}
	state:_clear_character_criminal_suspicion_data(key)
	return saved.status and saved or nil
end
guard_adapter.restore_alert = function(unit, saved)
	local state = managers.groupai:state()
	if saved.expire_t and saved.expire_t <= state._t then
		return
	end
	state:on_criminal_suspicion_progress(nil, unit, saved.status)
	local hud = state._suspicion_hud_data[unit:key()]
	if hud then
		hud._cst_local_alert_target = saved.local_target
		hud.expire_t = saved.expire_t
		hud.persistent = saved.persistent
	end
end
guard_adapter.clear_local_alert = function(unit)
	clear_unit_alert(unit)
end
guard_adapter.host_owns_alert = function(hud)
	hud._cst_local_alert_target = nil
end
guard_adapter.clear_session = function()
	for _, brain in pairs(brains) do
		retire_dart(brain)
		clear_local_alert(brain)
		clear(brain)
	end
end
guard_adapter.cleanup_target = function(target, preserve_local_alert)
	local key = target:key()
	importance[key] = nil
	refresh_importance()

	for _, brain in pairs(brains) do
		if not preserve_local_alert then
			clear_local_alert(brain, target)
		end
		local data = brain._cst_detection_data
		local entry = data and data.detected_attention_objects[key]

		if entry then
			CopLogicBase._destroy_detected_attention_object_data(data, entry)
		end

		reports.forget(brain, key)
	end
end
guard_adapter.remap_prediction = function(old_unit, new_unit, handler)
	local old_key, new_key = old_unit:key(), new_unit:key()
	for _, brain in pairs(brains) do
		local data = brain._cst_detection_data
		local entries = data and data.detected_attention_objects
		if entries and entries[old_key] then
			if old_key ~= new_key and entries[new_key] then
				CopLogicBase._destroy_detected_attention_object_data(data, entries[new_key])
			end
			world_target.remap_entry(entries, old_key, new_key, new_unit, handler)
			reports.remap(brain, old_key, new_key)
		end
	end
	if old_key ~= new_key then
		importance[new_key], importance[old_key] = importance[old_key], nil
	end
end
guard_adapter.refresh_prediction_reports = function(target)
	local key = target:key()
	for _, brain in pairs(brains) do
		reports.refresh(brain, key)
		brain._cst_next_detection_t = 0
	end
end
guard_adapter.seed_state = function(target, observations)
	local key = target:key()

	for _, observation in ipairs(observations or {}) do
		local brain = observation.observer_kind == "guard" and brains[observation.observer_id]
		local data = brain and brain._cst_detection_data

		if data then
			local entry = data.detected_attention_objects[key]
			if not entry and not observation.cleared then
				entry = create_attention_entry(data, brain._unit, key, data.t or TimerManager:game():time())
			end

			if entry then
				if observation.cleared then
					CopLogicBase._destroy_detected_attention_object_data(data, entry)
					entry = nil
				else
					entry.notice_progress = observation.notice_progress
					entry.uncover_progress = observation.uncover_progress
					entry.last_suspicion_t = entry.uncover_progress ~= nil and (data.t or TimerManager:game():time())
						or nil
					entry._cst_uncovered = entry.uncover_progress ~= nil and entry.uncover_progress >= 1
					entry.identified = observation.identified == true
					entry.verified = observation.verified == true
					entry.identified_t = entry.identified
							and (entry.identified_t or data.t or TimerManager:game():time())
						or nil
					entry.verified_t = entry.verified and (data.t or TimerManager:game():time()) or false
					entry.prev_notice_chk_t = entry.notice_progress ~= nil and (data.t or TimerManager:game():time())
						or nil
				end
			end

			local reported = entry and runtime:target_for_unit(target)
			reports.seed(brain, key, entry, reported)
		end
	end
end

function M.tweak_data_changed(self, key, old_tweak, new_tweak)
	local data = self._cst_detection_data
	if data then
		CopLogicBase.on_detected_attention_obj_tweak_data_changed(data, key, old_tweak, new_tweak)
	end
end

function M.attention_modified(self, key)
	local data = self._cst_detection_data
	local entry = data and data.detected_attention_objects[key]

	if not entry then
		return
	end

	local identified = entry.identified
	CopLogicBase.on_detected_attention_obj_modified(data, key)
	if identified and not entry.identified then
		reports.restart(self, key)
	end
end

function M.update_brains(t)
	if runtime.enabled == false or not features.allows_detection() then
		return
	end
	local active = runtime:is_active()
	for _, brain in pairs(brains) do
		update_detection(brain, t, active)
	end
end

function M.hostage_tied(self)
	local id = self._unit:id()
	if id ~= -1 then
		npc.unbind(self._unit)
		world_target.register("hostage", id, self._unit, nil, "civ_enemy_cbt")
	end
end

function M.hostage_untied(self)
	world_target.unregister_unit(self._unit)
end

function M.stop(self)
	retire_dart(self)
	npc.unbind(self._unit)
	clear_local_alert(self)
	clear(self)

	local id = self._cst_observer_id
	self._cst_observer_id = nil

	if id then
		brains[id] = nil
		runtime:unregister_observer("guard", id)
	end
end

function M.sync_surrender(self)
	if not self._dead then
		npc.sync_surrender(self._unit, self._surrendered == true)
	end
	if self._surrendered then
		retire_dart(self)
		if not surrender_pending(self._unit) then
			clear_local_alert(self)
		end
		clear(self)
	end
end

function M.sync_converted(self)
	retire_dart(self)
	npc.unbind(self._unit)
	clear_local_alert(self)
	clear(self)
end

function M.cool_changed(self, cool)
	if not cool then
		retire_dart(self)
		clear(self)
	end
end

function M.start()
	runtime = get_runtime()
	adapters:register("guard", guard_adapter)
end

return M
