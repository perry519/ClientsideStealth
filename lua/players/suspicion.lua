local get_runtime, adapters, restoring_call = ...
local M = {}

local notice_movement, notice_observer, notice_status

local function clear_feedback(unit)
	local movement = alive(unit) and unit.movement and unit:movement()
	if movement and movement._cst_local_suspicion then
		movement._cst_local_suspicion = nil
		movement._suspicion_ratio = false
		movement:_feed_suspicion_to_hud()
	end
end

local function clear_session()
	local player = managers.player and managers.player:player_unit()
	clear_feedback(player)
end

local function unmasked(movement)
	local state = movement._current_state_name
	return state == "mask_off" or state == "clean" or state == "civilian"
end

local function show_local(movement, observer_unit, status)
	local visible = managers.groupai:state():whisper_mode()
			and not managers.groupai:state():stealth_hud_disabled()
			and status
		or false
	local key = observer_unit:key()

	movement._cst_local_suspicion = movement._cst_local_suspicion or {}

	movement._cst_local_suspicion[key] = type(visible) == "number" and visible > 0 and visible or nil
	local maximum = visible == true
	if not maximum then
		for _, value in pairs(movement._cst_local_suspicion) do
			maximum = maximum == false and value or math.max(maximum, value)
		end
	end
	movement._suspicion_ratio = maximum

	movement:_feed_suspicion_to_hud()
end
M.show_local = show_local

local function apply_detection_report(report, observer, target)
	local movement = target.unit:movement()
	if not movement or not movement.on_suspicion or not alive(observer.unit) then
		return false
	end
	local casing = unmasked(movement)
	local transition, value = report.transition, report.value
	local suspicion
	if report.observer_kind == "guard" then
		if transition == "suspicion" and casing then
			suspicion = value >= 1 and true or value
		elseif transition == "notice" and not casing then
			suspicion = value
		elseif transition == "identified" and not casing then
			suspicion = true
		elseif transition == "lost" then
			suspicion = false
		end
	elseif report.observer_kind == "camera" then
		if transition == "suspicion" then
			suspicion = value
		elseif transition == "clear" or transition == "alarm" or transition == "notice" then
			suspicion = false
		end
	end
	if suspicion == nil then
		return false
	end
	show_local(movement, observer.unit, suspicion)
	if report.observer_kind == "guard" and transition == "suspicion" and casing then
		managers.groupai:state():on_criminal_suspicion_progress(target.unit, observer.unit, value)
		if value >= 1 then
			movement:on_uncovered(observer.unit)
		end
	end
	return true
end

local function show_remote(observer_unit, target_unit, status)
	local state = managers.groupai and managers.groupai:state()
	local huds = state and state._suspicion_hud_data
	if not huds or not state:whisper_mode() or not alive(observer_unit) or not alive(target_unit) then
		return
	end
	local key = observer_unit:key()
	local created = huds[key] == nil
	state:on_criminal_suspicion_progress(target_unit, observer_unit, status)
	if created and huds[key] then
		huds[key]._cst_preview = true
	end
end

local function withdraw_remote(observer_key, target_key)
	local state = managers.groupai and managers.groupai:state()
	local hud = state and state._suspicion_hud_data and state._suspicion_hud_data[observer_key]
	if not hud then
		return
	end
	if hud.suspects then
		hud.suspects[target_key] = nil
		if not next(hud.suspects) then
			hud.suspects = nil
		end
	end
	if hud._cst_preview and not hud.suspects and not hud.alerted then
		state:_clear_character_criminal_suspicion_data(observer_key)
	end
end

local function host_suspicion(state, observer_unit)
	local hud = state._suspicion_hud_data and state._suspicion_hud_data[observer_unit:key()]
	if hud then
		hud._cst_preview = nil
	end
end

local function invoke_notice(movement, notice, observer_unit, status)
	local previous_movement, previous_observer, previous_status = notice_movement, notice_observer, notice_status
	notice_movement, notice_observer, notice_status = movement, observer_unit, status
	return restoring_call(function()
		notice_movement, notice_observer, notice_status = previous_movement, previous_observer, previous_status
	end, notice, observer_unit, status)
end

local function local_notice(unit, notice)
	local movement = alive(unit) and unit.movement and unit:movement()
	if not movement then
		return notice
	end
	return function(observer_unit, status)
		return invoke_notice(movement, notice, observer_unit, status)
	end
end

function M.start()
	adapters:register("player", {
		clear_target = clear_feedback,
		clear_session = clear_session,
		apply_detection_report = apply_detection_report,
		local_notice = local_notice,
		show_remote = show_remote,
		withdraw_remote = withdraw_remote,
		host_suspicion = host_suspicion,
	})
end

function M.consume_local_notice(movement, observer_unit, status)
	if notice_movement ~= movement or notice_observer ~= observer_unit or notice_status ~= status then
		return false
	end
	notice_movement, notice_observer, notice_status = nil, nil, nil
	return true
end

function M.ignores_notice(movement, observer_unit)
	return unmasked(movement) and not observer_unit:base().is_security_camera
end

function M.replaces_native(movement, observer_unit)
	if observer_unit ~= nil or Network:is_server() then
		return false
	end
	local runtime = get_runtime()
	if not runtime:is_active() or not managers.groupai:state():whisper_mode() then
		return false
	end
	local player = managers.player and managers.player:player_unit()
	local peer_id = runtime.local_peer_id
	local target = peer_id and runtime:target_identity("player", peer_id)
	local owner = peer_id and runtime:target_owner("player", peer_id)
	return player and player:movement() == movement and target and target.unit == player and owner == peer_id or false
end

return M
