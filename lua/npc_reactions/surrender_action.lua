local cop_act = ...
local M = {}
local pending = {}
local remove_queued = cop_act.remove_queued

local QUEUED = { "walk", "predecessor", "aim", "pose", "turn", "idle2", "idle3" }

local function drop_queued(record)
	for _, field in ipairs(QUEUED) do
		remove_queued(record.movement, record[field])
		record[field] = nil
	end
end

local function now()
	return TimerManager:game():time()
end

local function usable(unit)
	local brain = unit:brain()
	return not unit:character_damage():dead() and not brain._dead and not brain._converted
end

local function retire(unit, resume)
	local record = pending[unit]
	if not record then
		return
	end
	pending[unit] = nil
	if not alive(unit) then
		return
	end
	local movement = record.movement
	remove_queued(movement, record.descriptor)
	if record.adopted then
		return
	end
	local actions = movement._active_actions
	local owned = actions[1] == record.action
	local can_resume = owned and resume and usable(unit) and not unit:brain()._surrendered
	if not can_resume then
		drop_queued(record)
	end
	if not owned then
		return
	end

	local host_stop = cop_act.exit_act(movement, record.action)
	if host_stop then
		movement:set_m_host_stop_pos(host_stop)
	end
	movement._ext_brain:action_complete_clbk(record.action)
	if can_resume then
		movement:_chk_start_queued_action()
		cop_act.idle_if_empty(movement)
	end
end

function M.begin(unit, deadline, is_current)
	assert(type(is_current) == "function", "[CST] surrender action needs an identity fence")
	if
		Network:is_server()
		or not alive(unit)
		or pending[unit]
		or not usable(unit)
		or deadline <= now()
		or not is_current()
	then
		return false
	end
	local movement = unit:movement()
	local actions = movement and movement._active_actions
	if not actions or not movement._queued_actions or next(movement._queued_actions) then
		return false
	end
	local ambient = cop_act.ambient_idle(unit, actions[1])
	for part = 1, 3 do
		local action = actions[part]
		if
			action
			and action ~= ambient
			and action:type() ~= "idle"
			and (part ~= 2 or action:type() ~= "walk" or not cop_act.ordinary_walk(action))
		then
			return false
		end
	end
	local walking = actions[2] and actions[2]:type() == "walk"
	if ambient and walking then
		return false
	end
	local saved_ambient
	if ambient then
		saved_ambient = cop_act.save_ambient(ambient)
		if not saved_ambient then
			return false
		end
	end
	local descriptor = {
		type = "act",
		body_part = 1,
		variant = "tied_all_in_one",
		clamp_to_graph = true,
		client_interrupt = true,
		block_type = walking and "light_hurt" or nil,
		blocks = {

			stand = -1,
			crouch = -1,
			turn = -1,
			walk = -1,
			act = -1,
			idle = -1,
			action = -1,
			light_hurt = -1,
			hurt = -1,
			heavy_hurt = -1,
			expl_hurt = -1,
			fire_hurt = -1,
		},
	}
	if cop_act.ambient_request(movement, descriptor, ambient, "chk_action_forbidden") then
		return false
	end
	local action = cop_act.ambient_request(movement, descriptor, ambient, "action_request")
	if not action or actions[1] ~= action then
		remove_queued(movement, descriptor)
		if saved_ambient and not actions[1] then
			movement:action_request(saved_ambient)
		end
		return false
	end
	local saved_walk = walking and cop_act.interrupted_walk(movement) or nil
	if saved_ambient then
		table.insert(movement._queued_actions, 1, saved_ambient)
	end

	local native_walk_block = action._blocks.walk
	action._blocks.walk = -1
	pending[unit] = {
		movement = movement,
		action = action,
		descriptor = descriptor,
		walk = saved_walk,
		predecessor = saved_ambient,
		native_walk_block = native_walk_block,
		deadline = deadline,
		is_current = is_current,
	}
	return true
end

function M.cancel(unit)
	retire(unit, true)
end

function M.blocks_equip(movement)
	local record = pending[movement._unit]
	return record ~= nil and movement._active_actions[1] == record.action
end

function M.before_request(movement, descriptor)
	local record = pending[movement._unit]
	if
		record
		and not record.adopted
		and not descriptor.client_interrupt
		and movement._active_actions[1] == record.action
	then
		local field = descriptor.body_part == 4
				and (descriptor.type == "stand" or descriptor.type == "crouch")
				and not descriptor.block_type
				and "pose"
			or descriptor.body_part == 2
				and descriptor.type == "turn"
				and (not descriptor.block_type or descriptor.block_type == "walk")
				and "turn"
		if field then
			remove_queued(movement, record[field])
			record[field] = descriptor
			return
		end
	end
	if
		record
		and not record.adopted
		and descriptor.type == "shoot"
		and descriptor.body_part == 3
		and descriptor.block_type == "action"
		and not descriptor.client_interrupt
		and movement._active_actions[1] == record.action
	then
		remove_queued(movement, record.aim)
		record.aim = descriptor
		return
	end
	if
		record
		and not record.adopted
		and descriptor.type == "idle"
		and (descriptor.body_part == 2 or descriptor.body_part == 3)
		and not descriptor.client_interrupt
		and movement._active_actions[1] == record.action
	then
		local field = "idle" .. descriptor.body_part
		remove_queued(movement, record[field])
		record[field] = descriptor
		return
	end
	if record and descriptor ~= record.descriptor and descriptor.body_part ~= 4 then
		retire(movement._unit, false)
	end
end

function M.act_started(movement, index, body_part, blocks_hurt, clamp_to_graph, needs_full_blend, start_rot, start_pos)
	local unit = movement._unit
	local record = pending[unit]
	if not record then
		return false
	end
	if not record.adopted and not record.is_current() then
		retire(unit, false)
		return false
	end
	local variant = movement._actions.act:_get_act_name_from_index(index)

	local predecessor
	if variant == "surprised" or variant == "arrest" then
		predecessor = not blocks_hurt and not clamp_to_graph and not needs_full_blend
	elseif variant == "idle" then
		predecessor = blocks_hurt and not clamp_to_graph and not needs_full_blend
	elseif variant == "distraction_dazed" then
		predecessor = blocks_hurt and not clamp_to_graph and needs_full_blend
	end
	if
		predecessor
		and not record.adopted
		and now() < record.deadline
		and body_part == 1
		and alive(unit)
		and usable(unit)
		and movement._active_actions[1] == record.action
	then
		remove_queued(movement, record.predecessor)
		record.predecessor = {
			type = "act",
			body_part = 1,
			variant = variant,
			start_rot = start_rot,
			start_pos = start_pos,
			clamp_to_graph = clamp_to_graph,
			needs_full_blend = needs_full_blend,
			blocks = { walk = -1, act = -1, idle = -1, action = -1, light_hurt = -1 },
		}
		if blocks_hurt then
			for _, name in ipairs({ "hurt", "heavy_hurt", "expl_hurt", "fire_hurt" }) do
				record.predecessor.blocks[name] = -1
			end
		end
		table.insert(movement._queued_actions, 1, record.predecessor)
		return true
	end
	if
		body_part ~= 1
		or variant ~= "tied_all_in_one"
		or not blocks_hurt
		or not clamp_to_graph
		or needs_full_blend
		or not alive(unit)
		or not usable(unit)
		or movement._active_actions[1] ~= record.action
		or not record.adopted and now() >= record.deadline
	then
		retire(unit, false)
		return false
	end
	if start_rot then
		movement:set_rotation(start_rot)
		movement:set_position(start_pos)
	end
	drop_queued(record)
	record.action._blocks.walk = record.native_walk_block

	for _, kind in ipairs({ "stand", "crouch", "turn" }) do
		record.descriptor.blocks[kind] = nil
		record.action._blocks[kind] = nil
	end
	record.adopted = true
	return true
end

function M.act_ending(movement, body_part)
	local record = pending[movement._unit]
	if not record or body_part ~= 1 then
		return false
	end
	local action, queued = movement:_get_latest_act_action(body_part)
	if queued and action == record.predecessor then
		remove_queued(movement, record.predecessor)
		record.predecessor = nil
		return true
	end
	if not queued and action == record.action then
		drop_queued(record)
		pending[movement._unit] = nil
	end
	return false
end

function M.update(t)
	t = t or now()
	for unit, record in pairs(pending) do
		if not alive(unit) then
			pending[unit] = nil
		elseif
			not usable(unit)
			or record.movement._active_actions[1] ~= record.action
			or not record.adopted and not record.is_current()
		then
			retire(unit, false)
		elseif t >= record.deadline then
			retire(unit, true)
		end
	end
end

function M.has_pending()
	return next(pending) ~= nil
end

function M.clear()
	for unit in pairs(pending) do
		retire(unit, true)
	end
end

return M
