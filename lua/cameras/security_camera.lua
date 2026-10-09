local get_runtime, camera_attention, Observer, host, client = ...
local M = {}
local detection_active, camera_id, blinded = Observer.detection_active, Observer.camera_id, Observer.blinded
local clear_detection, clear_remote_suspicion = camera_attention.clear_detection, client.clear_remote_suspicion

function M.update(camera, unit, t)
	if Network:is_server() or not detection_active() then
		return
	end
	if blinded(camera, true) then
		clear_detection(camera)
		camera:_stop_all_sounds()
		return
	end
	return client.update(camera, unit, t)
end

function M.detect(camera, t, native)
	local previous_last_detect_t = camera._last_detect_t
	local runtime = get_runtime()
	local id = not (camera._detection_interval ~= nil and t - camera._last_detect_t <= camera._detection_interval)
		and runtime:is_active()
		and camera_id(camera)
	local result
	if id then
		result = runtime:with_scope("camera", id, function()
			return native(camera, t)
		end)
	else
		result = native(camera, t)
	end

	camera._cst_detection_ticked = camera._detection_interval == nil or camera._last_detect_t ~= previous_last_detect_t
	if camera._cst_detection_ticked then
		client.finish_corpse_transitions(camera, true)
	end

	return result
end

function M.handles_alarm()
	return get_runtime():is_active()
end

function M.alarm(camera, detected_unit)
	if Network:is_server() then
		return host.alarm(camera, detected_unit)
	end
	return client.alarm(camera, detected_unit)
end

function M.register(camera)
	local id = camera_id(camera)

	if id then
		get_runtime():register_observer("camera", id, camera._unit, camera)
	end
end

function M.unregister(camera)
	client.clear_corpse_transitions(camera)
	local id = camera_id(camera)

	if id then
		local runtime = get_runtime()
		local removed = runtime:unregister_observer("camera", id, camera._unit)
		if removed and Network:is_server() then
			runtime:mark_state_dirty()
		end
	end

	clear_remote_suspicion(camera)
	host.forget(camera)
	client.forget_reports(camera)
	client.forget_loop(camera)
end

function M.detection_set(camera, state, settings)
	if settings then
		camera._cst_camera_settings = settings
		camera._cst_team_id = settings.team_id or camera._cst_team_id
	end

	if not state then
		clear_detection(camera)
	end

	if Network:is_server() then
		host.publish_state(camera, state, settings)
	end
end

function M.report(camera)
	if not camera._cst_detection_ticked or not get_runtime():is_active() then
		return
	end
	if Network:is_server() then
		return host.record_observations(camera)
	end
	return client.report(camera)
end

function M.raise_suspicion(camera)
	if not detection_active() then
		return
	end
	if blinded(camera) then
		clear_detection(camera)
	end

	camera._cst_suspicion_stack = camera._cst_suspicion_stack or {}
	camera._cst_suspicion_stack[#camera._cst_suspicion_stack + 1] = camera._suspicion == nil and false
		or camera._suspicion
	local remote = get_runtime():camera_suspicion(camera._unit)
	if remote and (not camera._suspicion or camera._suspicion < remote) then
		camera._suspicion = remote
	end
end

function M.restore_suspicion(camera)
	local stack = camera._cst_suspicion_stack

	if stack then
		local suspicion = table.remove(stack)

		camera._suspicion = suspicion == false and nil or suspicion
	end
end

function M.net_event(camera, event_id)
	local events = camera._NET_EVENTS
	local warning_event = event_id >= events.suspicion_1 and event_id <= events.suspicion_6
	if warning_event and not Network:is_server() and detection_active() then
		return true, client.warning_event(camera)
	end
	if event_id == events.start_tape_loop_1 or event_id == events.start_tape_loop_2 then
		client.loop_started(camera)
	end
	return false
end

function M.loop_requested(camera, event_id)
	if client.loop_requested(camera, event_id) then
		clear_detection(camera)
	end
end

function M.loop_restarted(camera)
	if not Network:is_server() and get_runtime():is_active() and camera._cst_detection_enabled then
		camera:set_update_enabled(true)
	end
end

return M
