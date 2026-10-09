local security_camera, observer, camera_attention, client = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	local original_upd_detection = SecurityCamera._upd_detection
	local original_sound_the_alarm = SecurityCamera._sound_the_alarm
	local original_sync_net_event = SecurityCamera.sync_net_event
	local original_tape_loop_expired = SecurityCamera._clbk_tape_loop_expired
	observer.bind(original_sound_the_alarm)

	Hooks:PostHook(SecurityCamera, "update", "ClientsideStealthCameraClientUpdate", security_camera.update)
	SecurityCamera._upd_detection = function(camera, t)
		return security_camera.detect(camera, t, original_upd_detection)
	end
	SecurityCamera._sound_the_alarm = function(camera, detected_unit)
		if not security_camera.handles_alarm() then
			return original_sound_the_alarm(camera, detected_unit)
		end
		return security_camera.alarm(camera, detected_unit)
	end
	Hooks:PostHook(SecurityCamera, "init", "ClientsideStealthCameraRegister", security_camera.register)
	Hooks:PreHook(SecurityCamera, "destroy", "ClientsideStealthCameraUnregister", security_camera.unregister)
	Hooks:PreHook(SecurityCamera, "set_detection_enabled", "ClientsideStealthCameraEnabled", function(camera, state)
		camera._cst_detection_enabled = state == true
	end)
	Hooks:PostHook(
		SecurityCamera,
		"set_detection_enabled",
		"ClientsideStealthCameraState",
		security_camera.detection_set
	)
	Hooks:PostHook(SecurityCamera, "_upd_detection", "ClientsideStealthCameraReportSuspicion", security_camera.report)
	Hooks:PreHook(
		SecurityCamera,
		"_upd_sound",
		"ClientsideStealthCameraRemoteSuspicionPre",
		security_camera.raise_suspicion
	)
	SecurityCamera.sync_net_event = function(camera, event_id, ...)
		local replaced, result = security_camera.net_event(camera, event_id)
		if replaced then
			return result
		end
		return original_sync_net_event(camera, event_id, ...)
	end
	SecurityCamera._clbk_tape_loop_expired = function(camera, ...)
		if not client.loop_expired(camera) then
			return original_tape_loop_expired(camera, ...)
		end
	end
	Hooks:PostHook(
		SecurityCamera,
		"_send_net_event",
		"ClientsideStealthCameraLoopRequest",
		security_camera.loop_requested
	)
	Hooks:PreHook(SecurityCamera, "_deactivate_tape_loop", "ClientsideStealthCameraLoopEnd", client.forget_loop)
	Hooks:PostHook(
		SecurityCamera,
		"_upd_sound",
		"ClientsideStealthCameraRemoteSuspicionPost",
		security_camera.restore_suspicion
	)
	Hooks:PostHook(
		SecurityCamera,
		"_deactivate_tape_loop_restart",
		"ClientsideStealthCameraResume",
		security_camera.loop_restarted
	)
	camera_attention.start()
end

return M
