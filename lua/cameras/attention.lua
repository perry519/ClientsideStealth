local world_target, get_runtime, adapters, camera_hud, camera_capture, Observer, host, client = ...
local M = {}
local camera_id, camera_base, target_identity, blinded =
	Observer.camera_id, Observer.camera_base, Observer.target_identity, Observer.blinded
local clear_remote_suspicion, clear_native_feedback = client.clear_remote_suspicion, Observer.clear_native_feedback
local runtime

function M.clear_detection(camera)
	client.clear_corpse_transitions(camera)
	local id = camera_id(camera)
	if Network:is_server() then
		if id then
			runtime:clear_camera_observations(id)
		end
		host.clear_observations(camera)
	elseif id then
		for _, prior in pairs(client.cached_reports(camera) or {}) do
			if prior.transition ~= "alarm" then
				runtime:send_report("camera", id, prior.kind, prior.id, "clear", 0)
			end
		end
	end

	camera:_destroy_all_detected_attention_object_data()
	clear_remote_suspicion(
		camera,
		camera._alarm_sound ~= nil or not (camera._tape_loop_expired_clbk_id or camera._tape_loop_restarting_t)
	)
	clear_native_feedback(camera)
end

local camera_adapter = {}
camera_adapter.is_jammed = Observer.camera_jammed
camera_adapter.target_hud_blocked = function(observer, active)
	local camera = observer.base and observer:base()
	return camera
		and (
			active and camera._cst_detection_enabled == false
			or camera._destroyed
			or camera._alarm_sound
			or blinded(camera)
		)
end
camera_adapter.apply_target_hud = function(observer, target, active)
	managers.groupai:state():on_criminal_suspicion_progress(target, observer, active and 1 or false)
end
camera_adapter.begin_corpse_transition = function(unit)
	if not Network:is_server() then
		client.begin_corpse_transition(unit)
	end
end
camera_adapter.end_corpse_transition = client.end_corpse_transition
camera_adapter.snapshot = function(camera)
	local base = camera_base(camera)
	return base and camera_capture.capture(base, base._cst_detection_enabled == true) or nil
end
camera_adapter.apply_state = function(camera, state)
	return camera_capture.apply(camera_base(camera), state)
end
camera_adapter.defer_corpse_hud = function(suspect, observer, status)
	return not Network:is_server() and client.defer_corpse_hud(suspect, observer, status)
end
camera_adapter.remap_prediction = function(old_unit, new_unit, handler, old_target_key, new_target_key, target)
	local old_key, new_key = old_unit:key(), new_unit:key()
	if not old_target_key then
		local _, _, target_key = target_identity(old_unit)
		old_target_key = target_key
	end
	if not new_target_key then
		local _, _, target_key = target_identity(new_unit)
		new_target_key = target_key
	end
	for _, camera_unit in ipairs(SecurityCamera.cameras) do
		local camera = alive(camera_unit) and camera_unit:base()
		local entries = camera and camera._detected_attention_objects
		if entries and entries[old_key] then
			if old_key ~= new_key and entries[new_key] then
				camera:_destroy_detected_attention_object_data(entries[new_key])
			end
			world_target.remap_entry(entries, old_key, new_key, new_unit, handler)
		end
		if camera then
			client.remap_report(camera, old_target_key, new_target_key, target)
		end
	end
end
camera_adapter.refresh_prediction_reports = function(target)
	local _, _, target_key = target_identity(target)
	if not target_key then
		return
	end
	for _, unit in ipairs(SecurityCamera.cameras) do
		local camera = alive(unit) and unit:base()
		if camera then
			client.refresh_report(camera, target_key, target)
		end
	end
end

camera_adapter.detection_entries = function(camera)
	if
		not Network:is_server()
		or not runtime:is_active()
		or not alive(camera._unit)
		or camera._destroyed
		or not camera._cst_detection_enabled
		or blinded(camera)
	then
		return nil
	end

	return runtime:camera_detection_entries(camera._unit)
end
camera_adapter.cleanup_target = function(camera_unit, target_unit, old)
	local camera = camera_unit:base()
	local state = managers and managers.groupai and managers.groupai:state()
	local hud = state and state._suspicion_hud_data and state._suspicion_hud_data[camera_unit:key()]
	local needs_clear = not Network:is_server() or hud or old and camera_hud:has_active_target(camera_unit, old)

	if target_unit and state and state.on_criminal_suspicion_progress and needs_clear then
		state:on_criminal_suspicion_progress(target_unit, camera_unit, false)
	end
	if old then
		runtime:apply_remote_camera_suspicion(camera_unit, old.kind .. ":" .. tostring(old.id), nil, old.owner_peer_id)
	end
	local attention = target_unit
		and camera._detected_attention_objects
		and camera._detected_attention_objects[target_unit:key()]
	if attention then
		camera:_destroy_detected_attention_object_data(attention)
	end
end
camera_adapter.clear_session = function(observers)
	host.clear()
	client.clear_reports()
	client.cancel_loop()
	for _, observer in pairs(observers) do
		if observer.kind == "camera" and alive(observer.unit) then
			client.clear_corpse_transitions(observer.unit:base())
		end
	end
	for _, observer in pairs(observers) do
		if observer.kind == "camera" and alive(observer.unit) then
			local camera = observer.unit:base()
			clear_remote_suspicion(camera)
			if not Network:is_server() then
				camera:_destroy_all_detected_attention_object_data()
				clear_native_feedback(camera)
			end
		end
	end
end
camera_adapter.seed_state = function(target, observations)
	local _, _, target_key = target_identity(target)
	local cameras = {}
	for _, unit in ipairs(SecurityCamera.cameras) do
		local camera = alive(unit) and unit:base()
		if camera and camera._detected_attention_objects then
			local id = camera_id(camera)
			if id then
				cameras[id] = camera
			end
		end
	end
	for _, observation in ipairs(observations or {}) do
		if observation.observer_kind == "camera" and (not target_key or not cameras[observation.observer_id]) then
			return false, "native_unavailable"
		end
	end

	for _, observation in ipairs(observations or {}) do
		if observation.observer_kind == "camera" then
			local camera = cameras[observation.observer_id]

			if camera then
				local key = target:key()
				local entry = camera._detected_attention_objects[key]

				if not entry and not observation.cleared then
					local attention =
						managers.groupai:state():get_AI_attention_objects_by_filter(camera._SO_access_str)[key]
					local settings = attention
						and attention.handler:get_attention(
							camera._SO_access,
							AIAttentionObject.REACT_SUSPICIOUS,
							nil,
							camera._team
						)

					if settings then
						entry = camera:_create_detected_attention_object_data(
							TimerManager:game():time(),
							key,
							attention,
							settings
						)
						camera._detected_attention_objects[key] = entry
					end
				end

				if entry then
					if observation.cleared then
						camera:_destroy_detected_attention_object_data(entry)
					else
						local uncover = observation.transition == "suspicion"
							and entry.reaction == AIAttentionObject.REACT_SUSPICIOUS
						entry.notice_progress = not uncover and observation.suspicion_progress or nil
						entry.uncover_progress = uncover and observation.suspicion_progress or nil
						entry.identified = observation.alarmed == true
						entry.prev_notice_chk_t = (entry.notice_progress ~= nil or entry.uncover_progress ~= nil)
								and TimerManager:game():time()
							or nil
					end
				end

				client.seed_report(camera, target_key, observation)
			end
		end
	end
	return true
end
camera_adapter.apply_report = host.apply_report

function M.start()
	runtime = get_runtime()
	adapters:register("camera", camera_adapter)
end

return M
