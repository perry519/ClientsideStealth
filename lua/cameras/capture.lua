local get_runtime, Observer = ...
local camera_id = Observer.camera_id
local M = {}

local function delay_values(delay)
	if not delay then
		return nil, nil
	end
	return delay.detection_delay_min or delay[1], delay.detection_delay_max or delay[2]
end

function M.capture(camera, enabled, settings)
	settings = settings or camera._cst_camera_settings or {}
	local delay_min, delay_max = delay_values(settings.detection_delay or camera._detection_delay)
	return {
		enabled = enabled,
		yaw = settings.yaw or camera._yaw,
		pitch = settings.pitch or camera._pitch,
		fov = settings.fov or camera._cone_angle,
		detection_range = settings.detection_range or camera._range,
		suspicion_range = settings.suspicion_range or camera._suspicion_range,
		delay_min = delay_min,
		delay_max = delay_max,
		team_id = settings.team_id or camera._cst_team_id or camera._team and camera._team.id,
		update_position = camera.update_position,
		driving = camera._driving,
		alarm = camera._alarm_sound ~= nil,
		ecm = managers.groupai:state():is_ecm_jammer_active("camera") or nil,
	}
end

function M.apply(camera, state)
	if not camera or not state then
		return false, "native_unavailable"
	end
	local delay
	if state.delay_min ~= nil or state.delay_max ~= nil then
		delay = { state.delay_min or state.delay_max or 0, state.delay_max or state.delay_min or 0 }
	end
	local settings = {
		yaw = state.yaw,
		pitch = state.pitch,
		fov = state.fov,
		detection_range = state.detection_range,
		suspicion_range = state.suspicion_range,
		detection_delay = delay,
		team_id = state.team_id,
	}
	local vanilla_settings = settings.yaw ~= nil and settings.pitch ~= nil and settings or nil
	local applying_snapshot = camera._cst_applying_snapshot
	camera._cst_applying_snapshot = true
	camera._cst_camera_settings = settings
	camera._cst_team_id = state.team_id
	camera._cst_remote_ecm = state.ecm == true
	camera:set_detection_enabled(state.enabled == true, vanilla_settings)
	if state.update_position ~= nil then
		camera:set_update_position(state.update_position == true)
	end
	if state.alarm and not camera._alarm_sound then
		Observer.sound_the_alarm(camera)
	elseif state.alarm == false and camera._alarm_sound then
		camera:_stop_all_sounds()
	end
	camera._cst_applying_snapshot = applying_snapshot
	if Network:is_server() then
		local id = camera_id(camera)
		if id then
			get_runtime():update_camera_state(id, M.capture(camera, state.enabled == true))
		end
	end
	return true
end

return M
