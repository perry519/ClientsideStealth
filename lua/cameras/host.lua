local Observer, get_runtime, capture = ...
local M = {}
local camera_id, camera_base, target_identity = Observer.camera_id, Observer.camera_base, Observer.target_identity
local camera_state = capture.capture
local world = setmetatable({}, { __mode = "k" })

function M.record_observations(camera)
	local runtime = get_runtime()
	local previous = world[camera] or {}
	local current = {}
	local id = camera_id(camera)
	if not id then
		return
	end

	for key, attention in pairs(camera._detected_attention_objects or {}) do
		local target = runtime:target_for_unit(attention.unit)

		if target then
			local old = previous[key]
			local value = attention.uncover_progress
			local notice = false
			if value == nil then
				value = attention.notice_progress
				notice = attention.reaction == AIAttentionObject.REACT_SUSPICIOUS
			end
			local transition = old and old.transition == "alarm" and "alarm"
				or value ~= nil and (notice and "notice" or "suspicion")
				or attention.identified and "notice"
				or nil
			value = value or transition == "notice" and 1 or nil
			current[key] = { target = target, transition = transition, value = value }

			if transition and (not old or old.transition ~= transition or old.value ~= value) then
				runtime:record_world_observation("camera", id, target.kind, target.id, transition, value or 1)
			end
		end
	end

	for key, old in pairs(previous) do
		if not current[key] and old.transition ~= "alarm" then
			runtime:record_world_observation("camera", id, old.target.kind, old.target.id, "clear", 0)
		end
	end

	world[camera] = current
end

function M.alarm(self, detected_unit)
	local runtime = get_runtime()
	local target = alive(detected_unit) and runtime:target_for_unit(detected_unit)
	if
		target
		and runtime:is_active()
		and not self._cst_applying_report
		and (
			runtime:is_detection_suppressed(detected_unit)
			or not runtime:owns_detection(target.kind, target.id, runtime.local_peer_id)
		)
	then
		return
	end
	local had_alarm = self._alarm_sound ~= nil
	local result = Observer.sound_the_alarm(self, detected_unit)
	local id = camera_id(self)

	if id and not had_alarm and self._alarm_sound and not self._cst_applying_snapshot then
		if target then
			runtime:record_world_observation("camera", id, target.kind, target.id, "alarm", 1)
			world[self] = world[self] or {}
			world[self][detected_unit:key()] = {
				target = target,
				transition = "alarm",
				value = 1,
			}
		end
		local record = runtime:update_camera_state(id, camera_state(self, self._cst_detection_enabled == true))

		if record then
			runtime:mark_state_dirty()
		end
	end

	return result
end

function M.publish_state(self, state, settings)
	local runtime = get_runtime()
	local id = camera_id(self)
	if id and not self._cst_applying_snapshot then
		local record = runtime:update_camera_state(id, camera_state(self, state == true, settings))

		if record then
			runtime:mark_state_dirty()
		end
	end
end

function M.apply_report(camera, target, transition, value, sender)
	local runtime = get_runtime()
	local base = camera_base(camera)

	if not base then
		return false
	end

	local _, _, target_key = target_identity(target)

	if not target_key then
		return false
	end

	local movement = target:movement()
	local suspicion = value

	local notice = transition == "notice"
	if transition == "clear" or transition == "alarm" or notice then
		suspicion = false
	end

	if movement and movement.on_suspicion then
		movement:on_suspicion(base._unit, suspicion)
	end
	managers.groupai:state():on_criminal_suspicion_progress(target, base._unit, transition == "alarm" or suspicion)

	runtime:apply_remote_camera_suspicion(base._unit, target_key, notice and value or suspicion or nil, sender, notice)

	if transition == "alarm" then
		base._cst_applying_report = true
		base:_sound_the_alarm(target)
		base._cst_applying_report = nil
	end

	return true
end

function M.clear_observations(camera)
	for key, old in pairs(world[camera] or {}) do
		if old.transition ~= "alarm" then
			world[camera][key] = nil
		end
	end
end

function M.forget(camera)
	world[camera] = nil
end

function M.clear()
	world = setmetatable({}, { __mode = "k" })
end

return M
