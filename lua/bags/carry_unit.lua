local Validation = assert((...), "ClientsideStealth: missing validation dependency")
local M = {}

function M.carry(unit)
	return alive(unit) and unit:carry_data() or nil
end

function M.interaction(unit)
	return alive(unit) and unit:interaction() or nil
end

function M.capture(unit)
	local int = M.interaction(unit)
	local bodies = {}
	for index = 0, unit.num_bodies and unit:num_bodies() - 1 or -1 do
		local body = unit:body(index)
		if alive(body) then
			bodies[#bodies + 1] = {
				body = body,
				enabled = body:enabled(),
			}
		end
	end
	return {
		position = unit:position(),
		rotation = unit:rotation(),
		visible = not unit.visible or unit:visible(),
		interaction_active = not int or not int.active or int:active(),
		bodies = bodies,
	}
end

local function restore_bodies(record)
	for _, state in ipairs(record.original.bodies or {}) do
		if alive(state.body) and state.body.set_enabled and state.body:enabled() ~= state.enabled then
			state.body:set_enabled(state.enabled)
		end
	end
end

function M.set_hidden(record, parent)
	local data = M.carry(record.unit)
	if not data or not alive(parent) then
		return false
	end

	M.cancel_teleport(data)
	if data._linked_to ~= parent then
		if data._linked_to then
			data:unlink()
		end
		data:link_to(parent)
	end
	record.unit:set_visible(false)
	local int = M.interaction(record.unit)
	if int and int.set_active then
		int:set_active(false)
	end
	return true
end

function M.rollback(record)
	if not record or not alive(record.unit) then
		return
	end
	local data = M.carry(record.unit)
	if data then
		data:unlink()
	end
	restore_bodies(record)
	record.unit:set_position(record.original.position)
	record.unit:set_rotation(record.original.rotation)
	record.unit:set_visible(record.original.visible)
	local int = M.interaction(record.unit)
	if int and int.set_active then
		int:set_active(record.original.interaction_active)
	end
end

function M.reveal(record)
	if not record or not alive(record.unit) then
		return
	end
	local data = M.carry(record.unit)
	if data then
		data:unlink()
	end
	restore_bodies(record)
	record.unit:set_visible(true)
	local int = M.interaction(record.unit)
	if int and int.set_active then
		int:set_active(true)
	end
end

function M.remove(record)
	if record and alive(record.unit) then
		record.unit:set_slot(0)
	end
end

function M.throw(record, position, rotation, direction, multiplier)
	local unit = record.unit
	local data = unit:carry_data()
	data:set_position_and_throw(position, direction * (600 * multiplier), 100)
	data._cst_bag_reset_motion = data._teleport_push

	unit:set_rotation(rotation)
end

function M.update_throw(data)
	if not data._cst_bag_reset_motion then
		return
	end
	if data._cst_bag_reset_motion ~= data._teleport_push then
		data._cst_bag_reset_motion = nil
		return
	end
	if not data._teleport_perform_push then
		return
	end
	data._cst_bag_reset_motion = nil

	local unit = data._unit
	local zero = Vector3(0, 0, 0)
	for index = 0, unit:num_bodies() - 1 do
		local body = unit:body(index)
		if alive(body) and body:dynamic() then
			body:set_velocity(zero)
			body:set_angular_velocity(zero)
		end
	end
end

function M.cancel_teleport(data)
	data._cst_bag_reset_motion = nil
	for _, body in ipairs(data._teleport_dynamic_bodies or {}) do
		if alive(body) then
			body:set_dynamic()
		end
	end
	data._teleport_pos = nil
	data._teleport_push = nil
	data._teleport_reset_dynamic_bodies = nil
	data._teleport_perform_push = nil
	data._teleport_dynamic_bodies = nil
end

function M.throw_multiplier(pm, carry_id, level)
	local carry_tweak = tweak_data.carry[carry_id]
	local carry_type = carry_tweak and tweak_data.carry.types[carry_tweak.type]
	if not carry_tweak or not carry_type then
		return nil
	end
	local multiplier = pm:upgrade_value_by_level("carry", "throw_distance_multiplier", level, 1)
		* carry_type.throw_distance_multiplier
	local mutators = managers.mutators
	local mutator = mutators
		and MutatorPiggyRevenge
		and mutators:is_mutator_active(MutatorPiggyRevenge)
		and mutators:get_mutator(MutatorPiggyRevenge)
	if mutator and mutator.get_bag_throw_multiplier then
		multiplier = multiplier * mutator:get_bag_throw_multiplier(carry_id)
	end
	return multiplier
end

function M.allow_local_throw()
	local player = managers.player and managers.player.player_unit and managers.player:player_unit()
	if alive(player) then
		player:movement():set_carry_restriction(false)
	end
end

function M.scalar(object, name)
	local member = object and object[name]
	return type(member) == "function" and member(object) or member
end

function M.same_vector(left, right, tolerance)
	if not left or not right then
		return false
	end
	for _, axis in ipairs({ "x", "y", "z" }) do
		local a, b = M.scalar(left, axis), M.scalar(right, axis)
		if
			not Validation.number(a, -1000000, 1000000)
			or not Validation.number(b, -1000000, 1000000)
			or math.abs(a - b) > (tolerance or 0.05)
		then
			return false
		end
	end
	return true
end

return M
