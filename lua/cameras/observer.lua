local get_runtime, features, equipment_ecm = ...
local M = {}

function M.bind(sound_the_alarm)
	M.sound_the_alarm = sound_the_alarm
end

function M.detection_active()
	return get_runtime():is_active() and features.allows_detection()
end

function M.camera_id(camera)
	local id = camera._unit:id()

	return id ~= -1 and id or nil
end

function M.camera_base(camera)
	return camera and (camera.base and camera:base() or camera) or nil
end

function M.target_identity(unit)
	local target = get_runtime():target_for_unit(unit)
	if target then
		return target.kind, target.id, target.key or target.kind .. ":" .. tostring(target.id)
	end
end

function M.camera_jammed(camera, active)
	local state = managers.groupai:state()
	if state:is_ecm_jammer_active("camera") or camera._cst_remote_ecm then
		return true
	end
	if not active and not get_runtime():is_active() then
		return false
	end
	if equipment_ecm:camera_jammed() then
		return true
	end

	local player = managers.player and managers.player:player_unit()
	local inventory = alive(player) and player:inventory()
	local jammer = inventory and inventory._jammer_data
	if not jammer or jammer.effect ~= "jamming" or not jammer.t or jammer.t <= TimerManager:game():time() then
		return false
	end

	local affects_cameras = inventory:get_jammer_affect()
	return affects_cameras == true
end

function M.blinded(camera, active)
	return M.camera_jammed(camera, active)
		or camera._tape_loop_expired_clbk_id ~= nil
		or camera._tape_loop_restarting_t ~= nil
end

function M.clear_native_feedback(camera)
	local state = managers.groupai:state()
	local hud = state._suspicion_hud_data and state._suspicion_hud_data[camera._unit:key()]
	if not hud or hud.alerted then
		return
	end

	local cleared
	for _, suspect in pairs(hud.suspects or {}) do
		local unit = suspect.u_suspect
		if alive(unit) then
			local movement = unit:movement()
			if movement and movement.on_suspicion then
				movement:on_suspicion(camera._unit, false)
			end
			state:on_criminal_suspicion_progress(unit, camera._unit, false)
			cleared = true
		end
	end
	if not cleared then
		state:on_criminal_suspicion_progress(nil, camera._unit, false)
	end
end

return M
