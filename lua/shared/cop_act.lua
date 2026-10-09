local M = {}

function M.ambient_idle(unit, action)
	local descriptor = action and action._action_desc
	local anim = descriptor and unit:anim_data()
	return descriptor
		and action:type() == "act"
		and descriptor.body_part == 1
		and not descriptor.clamp_to_graph
		and action._init_called
		and not action._expired
		and not action._host_expired
		and not unit:parent()
		and (anim.act_idle or anim.look)
		and action._blocks
		and action.save
		and action
end

function M.ambient_request(movement, descriptor, ambient, method)
	local blocks = ambient and ambient._blocks
	local act_block = blocks and blocks.act
	if blocks then
		blocks.act = nil
	end
	local result = movement[method](movement, descriptor)
	if blocks then
		blocks.act = act_block
	end
	return result
end

function M.ordinary_walk(action)
	local descriptor, blocks = action._action_desc, action._blocks
	if
		not descriptor
		or descriptor.type ~= "walk"
		or descriptor.body_part ~= 2
		or not descriptor.path_simplified
		or not descriptor.persistent
		or descriptor.variant ~= "walk" and descriptor.variant ~= "run"
		or action._old_blocks
		or action._nav_link
		or action._next_is_nav_link
		or not blocks
		or blocks.act ~= -1
		or blocks.idle ~= -1
		or blocks.turn ~= -1
		or blocks.walk ~= -1
	then
		return false
	end
	for name in pairs(blocks) do
		if name ~= "act" and name ~= "idle" and name ~= "turn" and name ~= "walk" then
			return false
		end
	end
	for _, point in ipairs(descriptor.nav_path or {}) do
		if type(point) == "table" and point.element then
			return false
		end
	end
	return true
end

function M.save_ambient(ambient)
	local saved = {}
	ambient:save(saved)
	if not saved.variant or not saved.start_anim_time then
		return nil
	end

	saved.start_rot, saved.start_pos = nil, nil
	saved.client_interrupt = true
	return saved
end

function M.interrupted_walk(movement)
	for _, queued in ipairs(movement._queued_actions) do
		if queued.type == "walk" and queued.body_part == 2 and queued.interrupted then
			return queued
		end
	end
end

function M.remove_queued(movement, descriptor)
	local queue = movement._queued_actions
	for i = #queue, 1, -1 do
		if queue[i] == descriptor then
			table.remove(queue, i)
		end
	end
end

function M.exit_act(movement, action)
	local host_stop = movement._m_host_stop_pos and mvector3.copy(movement._m_host_stop_pos)
	movement._active_actions[1] = false
	if action.on_exit then
		action:on_exit()
	end
	return host_stop
end

function M.idle_if_empty(movement)
	local actions = movement._active_actions
	if not actions[1] and not actions[2] and not actions[3] and not next(movement._queued_actions or {}) then
		movement:action_request({ type = "idle", body_part = 1, client_interrupt = true })
	end
end

return M
