local Observer, get_runtime, features = ...
local M = {}
local camera_id, target_identity = Observer.camera_id, Observer.target_identity
local reports = setmetatable({}, { __mode = "k" })

local function report_cache(camera)
	local cache = reports[camera]
	if not cache then
		cache = {}
		reports[camera] = cache
	end
	return cache
end
M.report_cache = report_cache

function M.forget_reports(camera)
	reports[camera] = nil
end

function M.clear_reports()
	reports = setmetatable({}, { __mode = "k" })
end

function M.cached_reports(camera)
	return report_cache(camera).reported
end

function M.remap_report(camera, old_key, new_key, target)
	if not old_key or not new_key or old_key == new_key then
		return
	end
	local cache = report_cache(camera)
	for _, field in ipairs({ "reported", "alarms" }) do
		local values = cache[field]
		if values and values[old_key] then
			values[new_key], values[old_key] = values[old_key], nil
			if field == "reported" then
				values[new_key].kind, values[new_key].id = target.kind, target.id
			end
		end
	end
end

function M.refresh_report(camera, target_key, target)
	local cache = report_cache(camera)
	local entry = camera._detected_attention_objects and camera._detected_attention_objects[target:key()]
	if cache.reported and entry and entry.unit == target then
		cache.reported[target_key] = nil
	end
	if cache.alarms then
		cache.alarms[target_key] = nil
	end
end

function M.seed_report(camera, target_key, observation)
	local cache = report_cache(camera)
	cache.reported = cache.reported or {}
	cache.reported[target_key] = not observation.cleared
			and {
				kind = observation.target_kind,
				id = observation.target_id,
				transition = observation.transition,
				value = observation.value,
			}
		or nil
end

function M.clear_remote_suspicion(camera, preserve_alarm)
	local runtime = get_runtime()
	local state = managers.groupai:state()
	for _, target_unit in ipairs(runtime:camera_contribution_targets(camera._unit)) do
		if alive(target_unit) then
			local movement = target_unit:movement()
			if movement and movement.on_suspicion then
				movement:on_suspicion(camera._unit, false)
			end
			state:on_criminal_suspicion_progress(target_unit, camera._unit, false)
		end
	end

	if Network:is_server() then
		runtime:apply_remote_camera_suspicion(camera._unit, nil, nil, nil)
	end
	local cache = report_cache(camera)
	if preserve_alarm then
		local retained
		for target_key, report in pairs(cache.reported or {}) do
			if report.transition == "alarm" then
				retained = retained or {}
				retained[target_key] = report
			end
		end
		cache.reported = retained
	else
		cache.reported = nil
		cache.alarms = nil
	end
end

local corpse_transitions = {}

local function release_corpse_transition(camera, pending)
	if not pending.clear_pending then
		return
	end
	pending.releasing = true
	managers.groupai:state():on_criminal_suspicion_progress(pending.unit, camera._unit, false)
	pending.releasing = nil
end

local function seeing_corpse_entry(camera, entry)
	local handler = entry and entry.handler
	if not handler or not entry.settings then
		return false
	end
	local position = handler:get_detection_m_pos()
	if not camera:_detection_angle_and_dis_chk(camera._pos, camera._look_fwd, handler, entry.settings, position) then
		return false
	end
	local ray = camera._unit:raycast(
		"ray",
		camera._pos,
		position,
		"slot_mask",
		camera._visibility_slotmask,
		"ray_type",
		"ai_vision"
	)
	return not ray or ray.unit == entry.unit
end

function M.finish_corpse_transitions(camera, ticked)
	local transitions = corpse_transitions[camera._unit:key()]
	if not transitions then
		return
	end
	for key, pending in pairs(transitions) do
		if not ticked or pending.registered then
			local entry = ticked and camera._detected_attention_objects and camera._detected_attention_objects[key]
			if entry and entry.unit == pending.unit and pending.corpse and seeing_corpse_entry(camera, entry) then
				if pending.clear_pending and not pending.fresh then
					managers.groupai:state():on_criminal_suspicion_progress(pending.unit, camera._unit, 0)
				end
			else
				release_corpse_transition(camera, pending)
			end
			transitions[key] = nil
		end
	end
	if not next(transitions) then
		corpse_transitions[camera._unit:key()] = nil
	end
end

function M.clear_corpse_transitions(camera)
	M.finish_corpse_transitions(camera, false)
end

function M.begin_corpse_transition(unit)
	local runtime = get_runtime()
	if not runtime:is_active() then
		return
	end
	local key = unit:key()
	for _, camera_unit in ipairs(SecurityCamera.cameras) do
		local camera = alive(camera_unit) and camera_unit:base()
		local entry = camera and camera._detected_attention_objects and camera._detected_attention_objects[key]
		if entry and entry.unit == unit then
			local camera_key = camera_unit:key()
			local transitions = corpse_transitions[camera_key] or {}
			transitions[key] = { unit = unit }
			corpse_transitions[camera_key] = transitions
		end
	end
end
function M.end_corpse_transition(unit)
	local runtime = get_runtime()
	local key = unit:key()
	local target = runtime:target_for_unit(unit)
	for _, transitions in pairs(corpse_transitions) do
		local pending = transitions[key]
		if pending and pending.unit == unit then
			pending.registered = true
			pending.corpse = target and target.kind == "corpse"
		end
	end
end
function M.defer_corpse_hud(suspect, observer, status)
	if not suspect or not observer then
		return false
	end
	local transitions = corpse_transitions[observer:key()]
	local pending = transitions and transitions[suspect:key()]
	if not pending or pending.unit ~= suspect or pending.releasing then
		return false
	end
	if status == false or status == nil then
		pending.clear_pending = true
		return true
	end
	if type(status) == "number" and status > 0 or status == true then
		pending.fresh = true
	end
	return false
end

function M.update(self, unit, t)
	local runtime = get_runtime()
	if self._detection_interval == nil or t - self._last_detect_t > self._detection_interval then
		self:_upd_detection(t)
	end

	if self._alarm_sound then
		return
	end

	if next(self._detected_attention_objects) ~= nil then
		local id = camera_id(self)

		if id then
			return runtime:with_scope("camera", id, function()
				return self:_upd_sound(unit, t)
			end)
		end
	end
	if not self._suspicion and not self._suspicion_sound and not runtime:camera_suspicion(self._unit) then
		return
	end

	self:_upd_sound(unit, t)
end

function M.alarm(self, detected_unit)
	local runtime = get_runtime()
	if self._cst_applying_snapshot or not alive(detected_unit) then
		return Observer.sound_the_alarm(self, detected_unit)
	end

	local scope = runtime:current_scope()
	local id = camera_id(self)
	if not scope or scope.kind ~= "camera" or scope.id ~= id then
		return
	end

	local target_kind, target_id, target_key = target_identity(detected_unit)

	if not target_kind then
		return
	end

	local cache = report_cache(self)
	cache.alarms = cache.alarms or {}

	if not cache.alarms[target_key] then
		cache.alarms[target_key] = true
		runtime:send_report("camera", id, target_kind, target_id, "alarm", 1)
	end
end

function M.report(self)
	local runtime = get_runtime()
	local id = camera_id(self)

	if not id then
		return
	end

	local cache = report_cache(self)
	local previous = cache.reported or {}
	local current = {}

	for _, attention in pairs(self._detected_attention_objects or {}) do
		local target_kind, target_id, target_key = target_identity(attention.unit)

		if target_kind and cache.alarms and cache.alarms[target_key] then
			current[target_key] = {
				kind = target_kind,
				id = target_id,
				transition = "alarm",
				value = 1,
			}
		elseif target_kind then
			local value = attention.uncover_progress
			local notice = false
			if value == nil then
				value = attention.notice_progress
				notice = attention.reaction == AIAttentionObject.REACT_SUSPICIOUS
			end
			local transition = value ~= nil and (notice and "notice" or "suspicion") or "clear"
			local prior = previous[target_key]

			current[target_key] = {
				kind = target_kind,
				id = target_id,
				transition = transition,
				value = value or 0,
			}

			if
				transition ~= "clear" and (not prior or prior.transition ~= transition or prior.value ~= value)
				or transition == "clear" and prior and prior.transition ~= "clear"
			then
				runtime:send_report("camera", id, target_kind, target_id, transition, value or 0)
			end
		end
	end

	for target_key, prior in pairs(previous) do
		if
			not current[target_key]
			and prior.transition ~= "clear"
			and (not cache.alarms or not cache.alarms[target_key])
		then
			runtime:send_report("camera", id, prior.kind, prior.id, "clear", 0)
		end
	end

	cache.reported = current
end

local predicted_loop

function M.forget_loop(camera)
	if predicted_loop == camera then
		predicted_loop = nil
	end
end

function M.cancel_loop()
	local camera = predicted_loop
	predicted_loop = nil
	if not camera or not alive(camera._unit) then
		return
	end
	camera:_deactivate_tape_loop()
	if not camera._destroyed and camera._unit:interaction() then
		camera._unit:interaction():set_active(true)
	end
end

function M.loop_requested(camera, event_id)
	local events = camera._NET_EVENTS
	local level = event_id == events.request_start_tape_loop_1 and 1
		or event_id == events.request_start_tape_loop_2 and 2
	if
		not level
		or camera._destroyed
		or Network:is_server()
		or not get_runtime():is_active()
		or not features.allows("camera_loop")
	then
		return false
	end
	camera:_start_tape_loop_by_upgrade_level(level)
	predicted_loop = camera
	return true
end

function M.loop_started(camera)
	if predicted_loop ~= camera then
		return M.cancel_loop()
	end
	predicted_loop = nil

	camera._unit:contour():remove("mark_unit_friendly")
end

function M.loop_expired(camera)
	if predicted_loop ~= camera then
		return false
	end
	camera._tape_loop_expired_clbk_id, camera._tape_loop_end_t = nil, nil
	M.cancel_loop()
	return true
end

function M.warning_event(self)
	if self._cst_detection_enabled and not self._destroyed and not self._alarm_sound and not Observer.blinded(self) then
		return self:_upd_sound(self._unit, TimerManager:game():time())
	end
	return
end

return M
