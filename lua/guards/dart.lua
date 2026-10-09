local get_runtime, adapters, control, cop_act, npc = ...
local M = {}
local pending = {}
local confirmed = {}
local disarmed = {}

local function release_contour(unit, record)
	if record and record.contour_id and alive(unit) then
		unit:contour():remove_by_id(record.contour_id, false)
	end
end

local function clear_confirmed(unit)
	release_contour(unit, confirmed[unit])
	confirmed[unit] = nil
end

local function now()
	return TimerManager:game():time()
end

local function free_guard(unit, movement)
	local brain, damage = unit:brain(), unit:character_damage()
	return brain
		and damage
		and not brain._dead
		and not brain._surrendered
		and not brain._converted
		and not brain._is_hostage
		and not damage:dead()
		and movement:cool()
		and not unit:in_slot(16)
end

local function wake(unit)
	local guard = adapters.guard
	if guard and guard.wake_detection then
		guard.wake_detection(unit)
	end
end

local function remove_saved_action(record, movement)
	if movement and movement._queued_actions then
		cop_act.remove_queued(movement, record.walk_descriptor)
		cop_act.remove_queued(movement, record.ambient_descriptor)
	end
end

local function remove_owned(record, replacing)
	local movement = record.unit:movement()
	if not movement then
		return
	end
	local actions = movement._active_actions
	if actions and actions[1] == record.action then
		local host_stop = cop_act.exit_act(movement, record.action)
		if host_stop and record.host_stop_pos and mvector3.distance_sq(host_stop, record.host_stop_pos) > 0 then
			movement:set_m_host_stop_pos(host_stop)
		end
		local can_resume = free_guard(record.unit, movement)
		if can_resume then
			movement:_chk_start_queued_action()
		else
			remove_saved_action(record, movement)
		end
		if can_resume and not replacing then
			cop_act.idle_if_empty(movement)
		end
		if movement._ext_brain then
			movement._ext_brain:action_complete_clbk(record.action)
		end
	end
	if movement._queued_actions then
		cop_act.remove_queued(movement, record.descriptor)
	end
end

function M:retire(unit, disarm, replacing)
	clear_confirmed(unit)
	local record = pending[unit]
	if not record then
		if not disarm then
			disarmed[unit] = nil
		end
		return false
	end
	pending[unit] = nil
	release_contour(unit, record)
	if alive(unit) then
		if replacing then
			remove_saved_action(record, unit:movement())
		end
		remove_owned(record, replacing)
		wake(unit)
	end

	disarmed[unit] = disarm and alive(unit) or nil
	return true
end

function M:clear()
	for unit in pairs(pending) do
		self:retire(unit)
	end
	for unit in pairs(confirmed) do
		clear_confirmed(unit)
	end
	pending = {}
	confirmed = {}
	disarmed = {}
end

function M:pending(unit)
	local record = pending[unit]
	return record ~= nil and alive(unit) and record.action == unit:movement()._active_actions[1]
end

local function current(record)
	local unit, runtime = record.unit, get_runtime()
	local movement = alive(unit) and unit:movement()
	return movement
		and free_guard(unit, movement)
		and runtime:session() == record.session
		and runtime:observer_identity(unit) == record.observer
		and record.observer.generation == record.generation
		and runtime.mode == "client_active"
		and runtime:is_active()
		and runtime:is_peer_capable(runtime.host_peer_id)
		and not managers.groupai:state():enemy_weapons_hot()
		and control.allows_new_work("dart")
end

function M:update(t)
	for unit, record in pairs(pending) do
		if not current(record) or record.action ~= unit:movement()._active_actions[1] then
			self:retire(unit)
		elseif t >= record.deadline then
			self:retire(unit, true)
		end
	end
	for unit, record in pairs(confirmed) do
		if not alive(unit) or unit:movement()._active_actions[1] ~= record.action then
			clear_confirmed(unit)
		end
	end
end

local function same_alignment(a, b, rotation)
	if a == b then
		return true
	end
	if not a or not b or type(a) ~= "userdata" or type(b) ~= "userdata" then
		return false
	end
	return rotation and mrotation.yaw(a) == mrotation.yaw(b) or not rotation and mvector3.distance_sq(a, b) < 0.01
end

local function defer_walk_alignment(record, movement, start_pos)
	return record.walk_descriptor
		and not record.walk_descriptor.no_walk
		and start_pos
		and managers.navigation
		and movement.nav_tracker
		and not managers.navigation:raycast({ tracker_from = movement:nav_tracker(), pos_to = start_pos })
end

local function eligible(unit, shooter, weapon)
	if Network:is_server() or not alive(unit) or not alive(weapon) then
		return false
	end
	local weapon_base = weapon:base()
	local selection = weapon_base and weapon_base.selection_index and weapon_base:selection_index()
	if not selection or selection <= 0 then
		return false
	end
	local player = managers.player and managers.player:player_unit()
	if not alive(player) or shooter ~= player or unit:id() < 0 or unit:in_slot(16) then
		return false
	end
	local runtime = get_runtime()
	if
		runtime.mode ~= "client_active"
		or not runtime:is_active()
		or not control.allows_new_work("dart")
		or not runtime:is_peer_capable(runtime.host_peer_id)
		or not runtime:observer_identity(unit)
	then
		return false
	end
	local state = managers.groupai:state()
	local base, movement = unit:base(), unit:movement()
	local tweak = base and base:char_tweak()
	local team = movement and movement:team()
	if
		state:enemy_weapons_hot()
		or not base
		or CopDamage.is_civilian(base._tweak_table)
		or not tweak
		or tweak.immune_to_daze
		or not tweak.detection
		or not tweak.detection.dazed
		or not movement
		or not free_guard(unit, movement)
		or team and team.friends and team.friends.criminal1
		or disarmed[unit]
		or pending[unit]
		or confirmed[unit]
	then
		return false
	end
	local actions = movement._active_actions
	local action = actions and actions[1]

	if action and action._action_desc and action._action_desc.variant == "distraction_dazed" then
		return false
	end
	local ambient = cop_act.ambient_idle(unit, action)
	if
		not actions
		or not movement._queued_actions
		or next(movement._queued_actions)
		or action and action:type() ~= "idle" and not ambient
		or actions[2] and actions[2]:type() ~= "walk" and actions[2]:type() ~= "idle"
		or actions[3] and actions[3]:type() ~= "idle"
	then
		return false
	end
	local walk = actions[2]
	if walk and walk:type() == "walk" and not cop_act.ordinary_walk(walk) then
		return false
	end
	local descriptor = {
		type = "act",
		body_part = 1,
		variant = "distraction_dazed",
		client_interrupt = true,
		blocks = { walk = -1, act = -1, idle = -1, action = -1, light_hurt = -1 },

		needs_full_blend = false,
	}
	if walk and walk:type() == "walk" then
		descriptor.block_type = "light_hurt"
	end
	if ambient and actions[2] and actions[2]:type() == "walk" then
		return false
	end
	if cop_act.ambient_request(movement, descriptor, ambient, "chk_action_forbidden") then
		return false
	end
	return true, runtime, movement, descriptor, ambient
end

function M.prepare_daze(unit, shooter, weapon)
	local ok, runtime, movement, descriptor, ambient = eligible(unit, shooter, weapon)
	return ok and { runtime = runtime, movement = movement, descriptor = descriptor, ambient = ambient } or nil
end

function M.apply_daze(unit, attempt)
	local runtime, movement, descriptor, ambient =
		attempt.runtime, attempt.movement, attempt.descriptor, attempt.ambient
	if ambient and movement._active_actions[1] ~= ambient then
		return
	end
	local t = now()
	local guard = adapters.guard
	local saved_ambient
	if ambient then
		saved_ambient = cop_act.save_ambient(ambient)
		if not saved_ambient then
			return
		end
	end
	local walking = movement._active_actions[2] and movement._active_actions[2]:type() == "walk"
	local action = guard
		and guard.touch_detection
		and guard.touch_detection(unit, t)
		and cop_act.ambient_request(movement, descriptor, ambient, "action_request")
	if action and movement._active_actions[1] == action then
		if saved_ambient then
			table.insert(movement._queued_actions, 1, saved_ambient)
		end
		local saved_walk = walking and cop_act.interrupted_walk(movement) or nil
		pending[unit] = {
			unit = unit,
			action = action,
			descriptor = descriptor,
			walk_descriptor = saved_walk,
			ambient_descriptor = saved_ambient,
			host_stop_pos = movement._m_host_stop_pos and mvector3.copy(movement._m_host_stop_pos),
			deadline = t + 2,
			session = runtime:session(),
			observer = runtime:observer_identity(unit),
			generation = runtime:observer_identity(unit).generation,
			contour_id = unit:contour():add("friendly", false),
		}
		wake(unit)
	else
		cop_act.remove_queued(movement, descriptor)
		if saved_ambient and not movement._active_actions[1] then
			movement:action_request(saved_ambient)
		end
		wake(unit)
	end
end

function M.predict_alert(unit, shooter, weapon, col_ray)
	local state = managers.groupai:state()
	local base, movement = unit:base(), unit:movement()
	local tweak = base and base.char_tweak and base:char_tweak()
	local team = movement and movement:team()
	local weapon_base = alive(weapon) and weapon:base()

	local selection = weapon_base and weapon_base.selection_index and weapon_base:selection_index()
	if
		Network:is_server()
		or not selection
		or selection <= 0
		or shooter ~= managers.player:player_unit()
		or not tweak
		or tweak.immune_to_daze
		or not team
		or team.friends.criminal1
		or not movement:cool()
		or state:enemy_weapons_hot()
	then
		return
	end
	local alert = { "aggression", col_ray.position, 260, state:get_unit_type_filter("law_enforcer"), unit }
	npc.predict_sound(state, alert, shooter)
end

function M.before_request(movement, descriptor)
	local record = pending[movement._unit]
	if record and descriptor ~= record.descriptor then
		M:retire(movement._unit, true, true)
	end
	disarmed[movement._unit] = nil
end

function M.after_request(movement)
	local adopted = confirmed[movement._unit]
	if adopted and movement._active_actions[1] ~= adopted.action then
		clear_confirmed(movement._unit)
	end
end

function M.act_started(movement, index, body_part, blocks_hurt, clamp_to_graph, needs_full_blend, start_rot, start_pos)
	local unit = movement._unit
	local record = pending[unit]
	local variant = (record or confirmed[unit]) and movement._actions.act:_get_act_name_from_index(index)
	local adopted = confirmed[unit]
	if
		not record
		and adopted
		and variant == "distraction_dazed"
		and body_part == 1
		and movement._active_actions[1] == adopted.action
		and blocks_hurt == adopted.blocks_hurt
		and clamp_to_graph == adopted.clamp_to_graph
		and needs_full_blend == adopted.needs_full_blend
		and same_alignment(start_rot, adopted.start_rot, true)
		and same_alignment(start_pos, adopted.start_pos, false)
	then
		return true
	end
	if record then
		if
			variant == "distraction_dazed"
			and body_part == 1
			and current(record)
			and now() < record.deadline
			and movement._active_actions[1] == record.action
			and not movement._ext_damage:dead()
			and needs_full_blend == true
			and not clamp_to_graph
		then
			local descriptor = record.action._action_desc
			local deferred = defer_walk_alignment(record, movement, start_pos)
			if not deferred then
				descriptor.start_rot, descriptor.start_pos = start_rot, start_pos
			end
			descriptor.clamp_to_graph, descriptor.needs_full_blend = clamp_to_graph, needs_full_blend
			descriptor.blocks.light_hurt = -1
			if blocks_hurt then
				for _, name in ipairs({ "hurt", "heavy_hurt", "expl_hurt", "fire_hurt" }) do
					descriptor.blocks[name] = -1
					record.action._blocks[name] = -1
				end
			end
			if start_rot and not deferred then
				movement:set_rotation(start_rot)
				movement:set_position(start_pos)
			end
			remove_saved_action(record, movement)
			pending[unit] = nil
			confirmed[unit] = {
				action = record.action,
				contour_id = record.contour_id,
				walk_descriptor = deferred and record.walk_descriptor,
				blocks_hurt = blocks_hurt,
				clamp_to_graph = clamp_to_graph,
				needs_full_blend = needs_full_blend,
				start_rot = start_rot,
				start_pos = start_pos and mvector3.copy(start_pos),
			}
			wake(unit)
			return true
		end
		M:retire(unit, true, true)
	end
	disarmed[unit] = nil
	return false
end

function M.act_ending(movement, body_part)
	local unit = movement._unit
	local latest, queued = movement:_get_latest_act_action(body_part)
	local record = pending[unit]
	if record and queued and latest == record.ambient_descriptor then
		remove_saved_action(record, movement)
		record.ambient_descriptor = nil
		return true
	end
	local owned = body_part == 1
		and not queued
		and latest
		and (pending[unit] and pending[unit].action == latest or confirmed[unit] and confirmed[unit].action == latest)
	local adopted = owned and confirmed[unit]
	local queue = movement._queued_actions
	if adopted and adopted.walk_descriptor and queue and not next(queue) then
		local target = adopted.start_pos
		if
			target
			and alive(unit)
			and free_guard(unit, movement)
			and mvector3.distance_sq(movement:m_pos(), target) > 1600
			and not managers.navigation:raycast({ tracker_from = movement:nav_tracker(), pos_to = target })
		then
			local walk = adopted.walk_descriptor
			walk.nav_path = { mvector3.copy(movement:m_pos()), mvector3.copy(target) }
			walk.persistent = nil
			walk.host_stop_pos_ahead = true
			walk.host_stop_pos_inserted = nil
			walk.end_rot = adopted.start_rot
			table.insert(queue, 1, walk)
		end
	end
	if owned and pending[unit] then
		remove_saved_action(pending[unit], movement)
		release_contour(unit, pending[unit])
		pending[unit] = nil
	end
	if body_part == 1 then
		if owned then
			clear_confirmed(unit)
		end
		disarmed[unit] = nil
	end
	return false, owned
end

function M.act_ended(unit)
	wake(unit)
end

return M
