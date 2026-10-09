local retained, Unit, Records, get_runtime, transport, secure = ...
local M = {}
M.candidates = {}
M.rejected_pickups = {}
M.next_generation = 0
local target, peer_id, session = retained.target, retained.peer_id, retained.session
local head, send, broadcast = retained.head, retained.send, retained.broadcast

function M.confirm_drop(unit, id, holder, source_unit, native_key, config)
	secure:track(unit, holder, native_key)
	get_runtime():confirm_prediction({
		kind = "bag",
		cause = "bag_drop",
		unit = unit,
		canonical_unit = unit,
		id = id,
		owner_peer_id = holder,
		source_unit = source_unit,
		native_key = native_key,
		config = config,
	})
end

local function release(record, position, rotation, direction, multiplier, prediction_token)
	local runtime = get_runtime()
	if not alive(record.unit) then
		return false
	end
	local data = Unit.carry(record.unit)
	if not data then
		return false
	end
	Unit.reveal(record)
	if data.set_latest_peer_id then
		data:set_latest_peer_id(record.peer_id)
	end
	Unit.throw(record, position, rotation, direction, multiplier)
	if data._global_event and managers.mission then
		managers.mission:call_global_event(data._global_event)
	end
	runtime:authorize_retained_bag_release(record.handoff)
	if prediction_token then
		local current = session()
		local peer = current and current:peer(record.peer_id)
		M.confirm_drop(record.unit, record.id, record.peer_id, peer and peer:unit(), prediction_token)
	end
	retained.retire(record)
	broadcast(head("release", record))
	return true
end

function M:can_retain(peer, unit)
	local runtime = get_runtime()
	self.candidates[unit] = nil
	if not Network:is_server() or not retained.preserve_pickup(unit, peer_id(peer)) then
		return false
	end
	if not peer or not peer.unit or not alive(peer:unit()) then
		return false
	end
	local holder = peer_id(peer)
	if not holder or retained.held[holder] then
		return false
	end
	local current = session()
	for id, candidate in pairs(current and current:peers() or {}) do
		if not candidate or not runtime:is_peer_capable(id) then
			return false
		end
	end
	local data, int = Unit.carry(unit), Unit.interaction(unit)
	local link_body = data._link_body
	local dynamic = alive(link_body) and link_body:dynamic()
	for _, body in ipairs(data._teleport_dynamic_bodies or {}) do
		if body == link_body then
			dynamic = true
			break
		end
	end
	if
		not link_body
		or not alive(link_body)
		or not link_body:enabled()
		or not dynamic
		or not int.active
		or not int:active()
	then
		return false
	end
	local bodies = unit.num_bodies and unit:num_bodies() or 0
	if bodies < 1 then
		return false
	end
	for index = 0, bodies - 1 do
		local body = unit:body(index)
		if not alive(body) then
			return false
		end
	end
	self.candidates[unit] = {
		peer_id = holder,
		original = Unit.capture(unit),
	}
	return true
end

function M:cancel_candidate(unit)
	local existed = self.candidates[unit] ~= nil
	self.candidates[unit] = nil
	return existed
end

function M:retain(unit, peer)
	local runtime = get_runtime()
	local id = peer_id(peer)
	local candidate = self.candidates[unit]
	if not candidate or candidate.peer_id ~= id or not alive(unit) or not alive(peer and peer:unit()) then
		return false
	end
	self.candidates[unit] = nil
	local bag, data = target(unit), Unit.carry(unit)
	if not bag or bag.kind ~= "bag" or not data then
		return false
	end
	secure:invalidate(unit)
	self.next_generation = self.next_generation + 1
	local generation = self.next_generation
	local record = {
		unit = unit,
		id = bag.id,
		incarnation = bag.incarnation,
		generation = generation,
		carry_id = data._carry_id,
		peer_id = id,
		original = candidate.original,
		held = true,
		native_approved = true,
		carry_multiplier = data._multiplier or 1,
		dye_initiated = data._dye_initiated,
		has_dye_pack = data._has_dye_pack,
		dye_value_multiplier = data._dye_value_multiplier,
	}
	retained.held[id] = record
	if not Unit.set_hidden(record, peer:unit()) then
		retained.held[id] = nil
		return false
	end
	local persistent = transport:mode(id) == "rpc"
	local prepared = runtime:prepare_retained_bag(bag.id, id, persistent)
	if not prepared then
		Unit.rollback(record)
		retained.held[id] = nil
		return false
	end
	record.handoff = prepared.handoff
	data._cst_bag_generation = generation
	bag = target(unit)
	if not bag then
		Unit.rollback(record)
		retained.held[id] = nil
		return false
	end
	local held = head("held", record)
	runtime:update_predictions()
	broadcast(held)
	runtime:send_retained_bag_activation(id, record.handoff)
	return record
end

function M:observe_pickup_request(peer, unit, unit_id, tweak_id, carry_id)
	local runtime = get_runtime()
	local id = peer_id(peer)
	if not Network:is_server() or not id or transport:mode(id) ~= "rpc" or not runtime:is_peer_capable(id) then
		return
	end
	self.rejected_pickups[id] = nil
	local int = Unit.interaction(unit)
	if unit_id ~= -2 and (not int or int.tweak_data ~= tweak_id or not int:active()) then
		self.rejected_pickups[id] = carry_id
	end
end

function M:server_drop(pm, args)
	local peer = args[11]
	local id = peer_id(peer)
	if id and self.rejected_pickups[id] then
		local rejected = self.rejected_pickups[id]
		self.rejected_pickups[id] = nil
		if rejected == args[1] then
			return true, nil
		end
	end
	local record = id and retained.held[id]
	if not record then
		return false, nil
	end
	local zipline = args[10]
	if alive(zipline) then
		Unit.remove(record)
		retained.retire(record)
		return false, nil
	end
	local carry_id = args[1]
	local multiplier = carry_id == record.carry_id
		and Unit.carry(record.unit)
		and Unit.throw_multiplier(pm, carry_id, args[9])
	if not multiplier then
		return true, nil
	end
	if not pm:verify_carry(peer, carry_id) then
		self:release_held(id)
		return true, nil
	end
	local released = release(record, args[6], args[7], args[8], multiplier)
	return true, released and record.unit or nil
end

function M:release_held(id)
	local record = retained.held[id]
	if not record then
		return false
	end
	Unit.remove(record)
	retained.retire(record)
	broadcast(head("release", record))
	return true
end

local function valid_retained_token(token, sender)
	if type(token) ~= "string" or #token > 64 then
		return false
	end
	local peer, ordinal = token:match("^retained:(%d+):(%d+)$")
	return tonumber(peer) == sender and ordinal ~= nil and tonumber(ordinal) > 0
end

local function reject_drop(record)
	send(record.peer_id, head("dropdeny", record))
	return false
end

function M:receive(sender, fields, id, incarnation, generation, holder)
	local runtime = get_runtime()
	local op = fields[1]
	if sender ~= holder or not runtime:is_peer_capable(sender) then
		return false
	end
	local record = retained.held[sender]
	if not record or record.id ~= id or record.incarnation ~= incarnation or record.generation ~= generation then
		local terminal = retained.history[holder]
		local key = table.concat({ id, incarnation, generation, holder }, ":")
		if not terminal or terminal.key ~= key then
			return false
		end
		if
			terminal.disposition ~= "retired"
			or op ~= "drop"
			or #fields ~= 17
			or not valid_retained_token(fields[17], sender)
		then
			return true
		end
		local retired = terminal.record
		local position, angles, direction, level = Records.drop_values(fields)
		local current = session()
		local peer = current and current:peer(sender)
		local pm = managers.player
		if fields[6] ~= retired.carry_id or not position or not angles or not direction or not level or not peer then
			return false
		end
		terminal.disposition = "fallback"
		local unit = pm:server_drop_carry(
			retired.carry_id,
			retired.carry_multiplier,
			retired.dye_initiated,
			retired.has_dye_pack,
			retired.dye_value_multiplier,
			Vector3(position[1], position[2], position[3]),
			Rotation(angles[1], angles[2], angles[3]),
			Vector3(direction[1], direction[2], direction[3]),
			level[1],
			nil,
			peer
		)
		if alive(unit) and runtime:target_identity_for_unit(unit) then
			M.confirm_drop(unit, unit:id(), sender, peer:unit(), fields[17])
		end
		return true
	end
	if op == "clear" and #fields == 5 then
		return self:release_held(sender)
	elseif
		op ~= "drop"
		or #fields ~= 17
		or type(fields[6]) ~= "string"
		or not fields[6]:match("^[%w_]+$")
		or not valid_retained_token(fields[17], sender)
	then
		return reject_drop(record)
	end
	local position, angles, direction, level = Records.drop_values(fields)
	if not position or not angles or not direction or not level or fields[6] ~= record.carry_id then
		return reject_drop(record)
	end
	local current = session()
	local peer = current and current:peer(sender)
	local pm = managers.player
	local multiplier = pm and Unit.carry(record.unit) and Unit.throw_multiplier(pm, record.carry_id, level[1])
	if not peer or not multiplier then
		return reject_drop(record)
	end
	if not pm:verify_carry(peer, record.carry_id) then
		self:release_held(sender)
		return false
	end
	local released = release(
		record,
		Vector3(position[1], position[2], position[3]),
		Rotation(angles[1], angles[2], angles[3]),
		Vector3(direction[1], direction[2], direction[3]),
		multiplier,
		fields[17]
	)
	return released or reject_drop(record)
end

function M:peer_added()
	local released = false
	for _, record in pairs(retained.held) do
		Unit.remove(record)
		retained.retire(record, "retired")
		broadcast(head("release", record))
		released = true
	end
	return released
end

function M:unit_destroyed(unit)
	self.candidates[unit] = nil
end

function M:peer_lost(id)
	self.rejected_pickups[id] = nil
	return self:release_held(id)
end

function M:reset()
	self.candidates, self.rejected_pickups, self.next_generation = {}, {}, 0
end

function M:retain_pickup(interaction, peer, player)
	local unit = interaction._unit
	local no_player = player == nil
	player = player or peer:unit()
	if not managers.player:register_carry(peer, unit:carry_data():carry_id()) then
		self:cancel_candidate(unit)
		return
	end
	if interaction._global_event then
		managers.mission:call_global_event(interaction._global_event, player)
	end
	if unit == managers.interaction:active_unit() then
		interaction:interact_interupt(managers.player:player_unit(), false)
	end
	interaction:remove_interact()
	interaction:set_active(false, true)
	if alive(player) then
		unit:carry_data():trigger_load(player)
	end
	if alive(unit) and not self:retain(unit, peer) then
		unit:set_slot(0)
	end
	managers.player:set_carry_approved(peer)
	if no_player then
		managers.mission:call_global_event("on_picked_up_carry", unit)
	end
end

return M
