local get_preview, get_runtime, control, Unit, restoring_call = ...
local M = {}
local drop_ordinals, receiving_native = {}, {}
local hidden_units = setmetatable({}, { __mode = "k" })
local sending_native

function M:is_suppressed(unit)
	if not alive(unit) then
		if unit then
			hidden_units[unit] = nil
		end
		return false
	end
	return hidden_units[unit] ~= nil
end

function M:has_suppressed_targets()
	local any = false
	for unit in pairs(hidden_units) do
		if alive(unit) then
			any = true
		else
			hidden_units[unit] = nil
		end
	end
	return any
end

function M:busy_for_pause()
	return self.pending ~= nil
end

function M:next_native_token(peer_id)
	if not peer_id then
		return nil
	end
	local ordinal = (drop_ordinals[peer_id] or 0) + 1
	drop_ordinals[peer_id] = ordinal
	return "bag:" .. peer_id .. ":" .. ordinal
end

function M:receiving_token(peer_id)
	return receiving_native[peer_id]
end

function M:with_drop_request(peer_id, callback, ...)
	local previous = receiving_native[peer_id]
	receiving_native[peer_id] = self:next_native_token(peer_id)
	return restoring_call(function()
		receiving_native[peer_id] = previous
	end, callback, ...)
end

function M:peer_lost(peer_id)
	drop_ordinals[peer_id], receiving_native[peer_id] = nil, nil
end

local function session()
	return managers.network and managers.network:session()
end

function M:corpse_died(unit, corpse)
	local runtime = get_runtime()
	if
		Network:is_server()
		or not control.allows_new_work("bag_handling")
		or not runtime:is_active()
		or not runtime:is_peer_capable(runtime.host_peer_id)
		or not corpse
		or not corpse.u_id
		or corpse.u_id == -1
		or corpse.unit and corpse.unit ~= unit
		or not unit:character_damage():dead()
		or not managers.groupai:state():whisper_mode()
		or unit:unit_data().has_alarm_pager
	then
		return
	end
	local interaction = unit:interaction()
	if not interaction or interaction.tweak_data == "corpse_alarm_pager" then
		return
	end
	if interaction.tweak_data == "corpse_dispose" and interaction:active() then
		return
	end
	interaction:set_tweak_data("corpse_dispose")
	interaction:set_active(true, false)
end

function M:keep_corpse_hidden(unit, corpse_id)
	local pickup = self.pending
	local hidden = pickup and pickup.hidden
	if not hidden or pickup.carry_id ~= "person" then
		return false
	end
	if not hidden.hidden or hidden.u_id ~= corpse_id then
		return false
	end
	if not alive(unit) then
		local corpse = managers.enemy:get_corpse_unit_data_from_id(corpse_id)
		unit = corpse and corpse.unit
	end
	return unit == hidden.unit
end

function M:outgoing_drop(network, carry_id)
	if network ~= session() or not network:server_peer() then
		return nil
	end
	if sending_native then
		local token = sending_native
		sending_native = nil
		return token
	end
	local peer = network:local_peer()
	local token = peer and self:next_native_token(peer:id())
	get_preview():native_drop_sent(token, carry_id)
	return token
end

local function send_native_drop(args)
	local current = session()
	if current and current:server_peer() then
		local peer = current:local_peer()
		local token = peer and M:next_native_token(peer:id())
		get_preview():native_drop_sent(token, args[1])
		local previous = sending_native
		sending_native = token
		restoring_call(function()
			sending_native = previous
		end, current.send_to_host, current, "server_drop_carry", (unpack or table.unpack)(args, 1, 10))
		return token
	end
end

local function hide_native_unit(pickup)
	local hidden = pickup and pickup.hidden
	local unit = hidden and hidden.unit
	if not alive(unit) then
		return false
	end
	hidden_units[unit] = hidden_units[unit]
		or {
			visible = hidden.visible,
			interaction_active = hidden.interaction_active,
		}
	unit:set_visible(false)
	local int = Unit.interaction(unit)
	if int and int.set_active then
		int:set_active(false)
	end
	hidden.hidden = true
	get_runtime():clear_local_detection(unit)
	return true
end

local function restore_hidden_unit(unit, snapshot)
	hidden_units[unit] = nil
	if not alive(unit) then
		return false
	end
	unit:set_visible(snapshot.visible)
	local int = Unit.interaction(unit)
	if int and int.set_active then
		int:set_active(snapshot.interaction_active)
	end
	return true
end

local function restore_native_unit(pickup)
	local hidden = pickup and pickup.hidden
	local unit = hidden and hidden.unit
	if not hidden or not hidden.hidden then
		return false
	end
	local restored = restore_hidden_unit(unit, hidden_units[unit] or hidden)
	hidden.hidden = nil
	return restored
end

function M:begin_pickup(carry_id, unit, corpse_id)
	local runtime = get_runtime()
	if
		Network:is_server()
		or not control.allows_new_work("bag_handling")
		or not runtime:is_active()
		or not runtime:is_peer_capable(runtime.host_peer_id)
	then
		return false
	end
	if self.pending and not self.pending.approved then
		return false
	end
	local int = unit and Unit.interaction(unit)
	self.pending = {
		carry_id = carry_id,
		hidden = alive(unit) and (corpse_id ~= nil or int and int._remove_on_interact) and {
			unit = unit,
			u_id = corpse_id,
			visible = not unit.visible or unit:visible(),
			interaction_active = not int or not int.active or int:active(),
		} or nil,
	}
	return true
end

local function approve_pending(owner, pickup)
	if pickup.approved then
		return false
	end
	pickup.approved = true
	if pickup.drop then
		owner.pending = nil
		send_native_drop(pickup.drop)
	end
	return true
end

function M:approve_corpse(corpse_id)
	local pickup = self.pending
	local corpse = pickup and pickup.hidden
	if not pickup or pickup.carry_id ~= "person" or not corpse or corpse.u_id ~= corpse_id then
		return false
	end
	return approve_pending(self, pickup)
end

function M:finish_pickup(success)
	if not self.pending then
		return false
	end
	if not success then
		restore_native_unit(self.pending)
		self.pending = nil
		return false
	end
	hide_native_unit(self.pending)
	Unit.allow_local_throw()
	return true
end

function M:request_drop(data, position, rotation, direction, level, zipline, immediate)
	local runtime = get_runtime()
	if
		Network:is_server()
		or not runtime:is_active() and not control.is_loud()
		or not runtime:is_peer_capable(runtime.host_peer_id)
	then
		return false
	end
	position = Vector3(Unit.scalar(position, "x"), Unit.scalar(position, "y"), Unit.scalar(position, "z"))
	direction = Vector3(Unit.scalar(direction, "x"), Unit.scalar(direction, "y"), Unit.scalar(direction, "z"))
	rotation = Rotation(Unit.scalar(rotation, "yaw"), Unit.scalar(rotation, "pitch"), Unit.scalar(rotation, "roll"))
	local args = {
		data.carry_id,
		data.multiplier,
		data.dye_initiated,
		data.has_dye_pack,
		data.dye_value_multiplier,
		position,
		rotation,
		direction,
		level,
		zipline,
	}
	local pickup = self.pending
	if not immediate and pickup and pickup.carry_id == data.carry_id and not pickup.approved then
		pickup.drop = args
	else
		self.pending = nil
		return true, send_native_drop(args)
	end
	return true
end

function M:reply(status, carry_id)
	local pickup = self.pending
	local corpse_reply = pickup and pickup.carry_id == "person" and (carry_id == nil or carry_id == "")
	if pickup and (pickup.carry_id == carry_id or corpse_reply) then
		if status == true then
			return true, approve_pending(self, pickup)
		elseif pickup.approved then
			return true, false
		end
		restore_native_unit(pickup)
		self.pending = nil
		get_preview():reject(pickup.carry_id)
		local pm = managers.player
		local inventory = pm:get_my_carry_data()
		if inventory and inventory.carry_id == pickup.carry_id then
			pm:clear_carry()
		end
		return true, false
	end
	return false
end

function M:pending_carry_id()
	return self.pending and self.pending.carry_id
end

function M:pickup_pending()
	return self.pending ~= nil and not self.pending.approved
end

function M:discard()
	self.pending = nil
end

function M:reset(preserve_drop_ordinals)
	restore_native_unit(self.pending)
	for unit, snapshot in pairs(hidden_units) do
		restore_hidden_unit(unit, snapshot)
	end
	self:discard()
	receiving_native = {}
	if not preserve_drop_ordinals then
		drop_ordinals = {}
	end
end

function M:resume_drop(data, position, rotation, direction, level, approved)
	self.pending = { carry_id = data.carry_id, approved = approved }
	get_preview():predict(data, position, rotation, direction, level)
	return self:request_drop(data, position, rotation, direction, level)
end

return M
