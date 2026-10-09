local retained, carry_requests, Unit, get_runtime, control, transport, world_target = ...
local M = {}
M.skips = {}
M.observer_pickups = {}
M.pending_held = {}
M.inflight = {}
M.next_prediction_token = 0
local target, session, resolve = retained.target, retained.session, retained.resolve
local head, send, remember = retained.head, retained.send, retained.remember

local function record_busy_for_pause(record)
	return record.held ~= false or not record.native_replied or record.held_confirmed and not record.terminal
end

function M:busy_for_pause(local_only)
	if
		self.pending and record_busy_for_pause(self.pending)
		or self.local_record and record_busy_for_pause(self.local_record)
	then
		return true
	end
	for _, record in pairs(self.inflight) do
		if record_busy_for_pause(record) then
			return true
		end
	end
	return not local_only and next(self.observer_pickups) ~= nil
end

function M:holds(unit)
	local record = self.local_record
	return record ~= nil and record.unit == unit and record.held == true
end

function M:holds_any()
	return self.local_record ~= nil and self.local_record.held == true
end

function M:can_finish_drop(data)
	local runtime = get_runtime()
	if control.allows_new_work("bag_handling") then
		return true
	end
	if control.is_preparing() or runtime.enabled == false then
		return false
	end
	local carry_id = data and (data.carry_id or data._carry_id)
	return carry_id ~= nil
		and (
			self.local_record and self.local_record.carry_id == carry_id
			or carry_requests:pending_carry_id() == carry_id
		)
end

local function prune_inflight()
	for index = #M.inflight, 1, -1 do
		local record = M.inflight[index]
		if record.terminal and record.native_replied then
			table.remove(M.inflight, index)
		end
	end
end

local function local_records()
	local records = {}
	for _, record in ipairs(M.inflight) do
		records[#records + 1] = record
	end
	if M.local_record then
		records[#records + 1] = M.local_record
	end
	return records
end

local function newer_local(record)
	local found = false
	for _, candidate in ipairs(local_records()) do
		if found and candidate.unit == record.unit and not candidate.terminal then
			return true
		end
		found = found or candidate == record
	end
	return false
end

local function find_local(id, incarnation, generation, unconfirmed)
	for _, record in ipairs(local_records()) do
		if not record.terminal and record.id == id then
			if record.held_confirmed and record.incarnation == incarnation and record.generation == generation then
				return record
			end
			if
				unconfirmed
				and not record.held_confirmed
				and (record.incarnation == incarnation or record.incarnation == 0)
			then
				local bag = target(record.unit)
				if bag and bag.unit == record.unit and (bag.incarnation == incarnation or bag.incarnation == 0) then
					return record
				end
			end
		end
	end
end

function M:awaits_host_records()
	if self.pending and self.pending.pipeline then
		return true
	end
	for _, record in ipairs(local_records()) do
		if record.pipeline and not record.terminal then
			return true
		end
	end
	return false
end

local function finish_local(record)
	record.terminal = true
	if M.pending == record then
		M.pending = nil
	end
	if M.local_record == record then
		M.local_record = nil
		if record.pipeline and not record.native_replied then
			M.inflight[#M.inflight + 1] = record
		end
	end
	prune_inflight()
end

function M:begin_observer_pickup(unit, holder)
	local runtime = get_runtime()
	if
		Network:is_server()
		or not runtime:is_active()
		or not alive(unit)
		or not target(unit)
		or not Unit.carry(unit)
	then
		return false
	end
	if self.pending and self.pending.unit == unit then
		return true
	end
	if retained.holding(unit) then
		self.observer_pickups[unit] = nil
		return true
	end
	if self.observer_pickups[unit] then
		return true
	end
	if not control.allows_new_work("bag_handling", holder) then
		return false
	end
	self.observer_pickups[unit] = Unit.capture(unit)
	return true
end

function M:finish_observer_pickup(unit)
	if self.pending and self.pending.unit == unit then
		return true
	end
	if retained.holding(unit) then
		self.observer_pickups[unit] = nil
		return true
	end
	if alive(unit) then
		return self.observer_pickups[unit] ~= nil
	end
	self.observer_pickups[unit] = nil
	return false
end

function M:archive_drop()
	local record = self.local_record
	if record and record.pipeline and record.held == false then
		self.inflight[#self.inflight + 1] = record
		self.local_record = nil
		if self.pending == record then
			self.pending = nil
		end
	end
end

function M:begin_pickup(unit)
	local runtime = get_runtime()
	local bag, data = target(unit), Unit.carry(unit)
	if Network:is_server() or not retained.preserve_pickup(unit) or not bag or bag.kind ~= "bag" or not data then
		return false
	end
	local generation = (data._cst_bag_generation or 0) + 1
	self:archive_drop()
	self.pending = {
		unit = unit,
		id = bag.id,
		incarnation = bag.incarnation,
		generation = generation,
		carry_id = data._carry_id,
		peer_id = runtime.local_peer_id,
		original = Unit.capture(unit),

		pipeline = transport:mode(runtime.host_peer_id) == "rpc",
	}
	return true
end

function M:finish_pickup(unit, result)
	local runtime = get_runtime()
	local record = self.pending
	if not record or record.unit ~= unit then
		return false
	end
	if not result then
		self.pending = nil
		return false
	end
	local current = session()
	local local_peer = current and current:local_peer()
	if not local_peer or not Unit.set_hidden(record, local_peer:unit()) then
		self.pending = nil
		return false
	end
	record.held = true
	self.local_record = record
	runtime:clear_local_detection(unit)
	runtime:suspend_target_observations("bag", record.id, true, record.pipeline == true)
	Unit.allow_local_throw()
	return true
end

function M:reply(status, carry_id)
	local runtime = get_runtime()
	local record
	for _, candidate in ipairs(local_records()) do
		if candidate.pipeline and not candidate.native_replied then
			record = candidate
			break
		end
	end
	if not record then
		local handled, result = carry_requests:reply(status, carry_id)
		if handled then
			return result
		end
		record = self.local_record or self.pending
	end
	if not record or carry_id ~= record.carry_id then
		return false
	end
	local stale = record.pipeline and (record ~= self.local_record or record.held == false or record.terminal)
	record.native_replied = true
	if status == true or status == "accepted" or status == "held" then
		record.native_approved = true
		prune_inflight()
		return true, stale
	end
	local data = Unit.carry(record.unit)
	local newer = newer_local(record)
	if data and not newer then
		Unit.cancel_teleport(data)
	end
	for index = #self.skips, 1, -1 do
		if self.skips[index].record == record then
			table.remove(self.skips, index)
		end
	end
	if retained.holding(record.unit) then
		finish_local(record)
		return false, stale
	end
	if not newer then
		Unit.rollback(record)
	end
	finish_local(record)
	runtime:restore_target_observations("bag", record.id)
	return false, stale
end

function M:pickup_pending()
	return carry_requests:pickup_pending()
		or self.local_record ~= nil
			and (self.local_record.pending_clear or not self.local_record.pipeline and (self.local_record.pending_drop ~= nil or self.local_record.held == false))
end

function M:predict_drop(data, position, rotation, direction, level, zipline)
	local runtime = get_runtime()
	if not self:can_finish_drop(data) then
		return false
	end
	local record = self.local_record
	local carry_id = data and (data.carry_id or data._carry_id)
	if not record or carry_id ~= record.carry_id or alive(zipline) then
		return false
	end
	if record.pending_drop or record.pipeline and record.held == false then
		return true, "drop_pending"
	end
	local pm = managers.player
	local multiplier = pm and Unit.throw_multiplier(pm, record.carry_id, level)
	local extension = Unit.carry(record.unit)
	if not multiplier or not extension then
		return false
	end
	position = Vector3(Unit.scalar(position, "x"), Unit.scalar(position, "y"), Unit.scalar(position, "z"))
	record.inventory = {
		carry_id = data.carry_id,
		multiplier = data.multiplier,
		dye_initiated = data.dye_initiated,
		has_dye_pack = data.has_dye_pack,
		dye_value_multiplier = data.dye_value_multiplier,
	}
	if record.pipeline then
		local requested, token = carry_requests:request_drop(data, position, rotation, direction, level, zipline, true)
		if not requested then
			return false
		end
		record.prediction_token = token
	else
		self.next_prediction_token = self.next_prediction_token + 1
		record.prediction_token = "retained:" .. record.peer_id .. ":" .. self.next_prediction_token
		local fields = {
			"drop",
			record.id,
			record.incarnation,
			record.generation,
			record.peer_id,
			record.carry_id,
			Unit.scalar(position, "x"),
			Unit.scalar(position, "y"),
			Unit.scalar(position, "z"),
			Unit.scalar(rotation, "yaw"),
			Unit.scalar(rotation, "pitch"),
			Unit.scalar(rotation, "roll"),
			Unit.scalar(direction, "x"),
			Unit.scalar(direction, "y"),
			Unit.scalar(direction, "z"),
			level,
			record.prediction_token,
		}
		if record.held_confirmed then
			send(runtime.host_peer_id, fields)
		else
			record.pending_drop = fields
		end
	end
	Unit.reveal(record)
	Unit.throw(record, position, rotation, direction, multiplier)
	record.held = false
	local current = session()
	local local_peer = current and current:local_peer()
	if
		control.allows_new_work("bag")
		and local_peer
		and not runtime:owns_detection("bag", record.id, record.peer_id)
	then
		local config = world_target.config(record.unit)
		if config then
			record.prediction = runtime:predict_target({
				kind = "bag",
				id = record.id,
				unit = record.unit,
				owner_peer_id = record.peer_id,
				source_unit = local_peer:unit(),
				cause = "bag_drop",
				native_key = record.prediction_token,
				config = config,
				attention = world_target.prediction_attention(record.unit, config),
			})
		end
	end
	self.skips[#self.skips + 1] = {
		record = record,
		unit = record.unit,
		position = position,
		direction = direction * (600 * multiplier),

		direction_tolerance = record.pipeline and 0.05 * (600 * multiplier + 1) or nil,
		force = 100,
	}
	return true
end

function M:skip_interaction(unit)
	for _, record in ipairs(local_records()) do
		if record.pipeline and record.unit == unit and not record.interaction_seen then
			record.interaction_seen = true
			return record.held == false and not retained.is_suppressed(unit)
		end
	end
	return false
end

function M:skip_link(unit, parent)
	for _, marker in ipairs(self.skips) do
		if marker.unit == unit then
			return true
		end
	end
	local record = self.local_record
	if not record or record.unit ~= unit then
		return false
	end
	local data = Unit.carry(unit)
	return record.held and data and data._linked_to == parent or false
end

function M:skip_rethrow(unit, position, direction, force)
	for index, marker in ipairs(self.skips) do
		if
			marker.unit == unit
			and marker.force == force
			and Unit.same_vector(marker.position, position)
			and Unit.same_vector(marker.direction, direction, marker.direction_tolerance)
		then
			table.remove(self.skips, index)
			return true
		end
	end
	return false
end

function M:clear_local()
	local runtime = get_runtime()
	carry_requests:discard()
	local record = self.local_record
	if not record then
		return false
	end
	if record.pipeline and record.held == false then
		return false
	end
	if record.pending_clear then
		return true
	end
	if not record.held_confirmed then
		record.pending_clear = true
		return true
	end
	send(runtime.host_peer_id, head("clear", record))
	finish_local(record)
	return true
end

local function queue_held(self, fields, id, incarnation, generation, holder, unit)
	local queued = self.pending_held[holder]
	if not queued or generation >= queued.generation then
		self.pending_held[holder] = {
			fields = fields,
			id = id,
			incarnation = incarnation,
			generation = generation,
			unit = unit,
		}
	end
	return true
end

local function receive_held(self, fields, id, incarnation, generation, holder)
	local runtime = get_runtime()
	local bag = resolve(id, incarnation)
	local record = find_local(id, incarnation, generation, true)

	if
		not bag
		and holder == runtime.local_peer_id
		and record
		and record.id == id
		and record.incarnation == 0
		and not record.held_confirmed
	then
		local pending_target = target(record.unit)
		if
			pending_target
			and pending_target.kind == "bag"
			and pending_target.id == id
			and pending_target.incarnation == 0
			and pending_target.unit == record.unit
		then
			bag = pending_target
		end
	end
	local current = session()
	local holder_peer = current and (holder == runtime.local_peer_id and current:local_peer() or current:peer(holder))
	local terminal = retained.history[holder]
	if terminal and generation <= terminal.generation then
		return false
	end
	if not bag then
		local pending_target = runtime:target_identity("bag", id)
		local previous = retained.held[holder]
		if
			holder ~= runtime.local_peer_id
			and pending_target
			and pending_target.incarnation == 0
			and alive(pending_target.unit)
			and (not previous or generation > previous.generation)
		then
			return queue_held(self, fields, id, incarnation, generation, holder, pending_target.unit)
		end
		return false
	end
	local previous, same_unit
	if holder == runtime.local_peer_id then
		if not record or record.id ~= id or record.unit ~= bag.unit then
			return false
		end
		if record.held_confirmed then
			return generation == record.generation
		end
		record.generation = generation
	else
		local data = Unit.carry(bag.unit)
		if not holder_peer or not data then
			return queue_held(self, fields, id, incarnation, generation, holder, bag.unit)
		end
		previous = retained.held[holder]
		if previous then
			if generation <= previous.generation then
				return previous.id == id and previous.incarnation == incarnation and previous.generation == generation
			end
			same_unit = previous.unit == bag.unit
		end
		record = {
			unit = bag.unit,
			id = id,
			incarnation = incarnation,
			generation = generation,
			carry_id = data._carry_id,
			peer_id = holder,
			original = same_unit and previous.original or self.observer_pickups[bag.unit] or Unit.capture(bag.unit),
			held = true,
			native_approved = true,
		}
	end
	local drop_pending = holder == runtime.local_peer_id and record.held == false
	if not holder_peer or not drop_pending and not Unit.set_hidden(record, holder_peer:unit()) then
		return holder ~= runtime.local_peer_id
				and queue_held(self, fields, id, incarnation, generation, holder, bag.unit)
			or false
	end
	if holder ~= runtime.local_peer_id then
		if previous then
			if not same_unit then
				Unit.reveal(previous)
			end
			remember(previous)
		end
		self.observer_pickups[bag.unit] = nil
		retained.held[holder] = record
	end
	record.native_approved = true
	record.held = not drop_pending
	record.held_confirmed = true
	record.incarnation = incarnation
	local queued = self.pending_held[holder]
	if queued and generation >= queued.generation then
		self.pending_held[holder] = nil
	end
	local data = Unit.carry(record.unit)
	if not data then
		return false
	end
	data._cst_bag_generation = math.max(data._cst_bag_generation or 0, generation)
	if holder == runtime.local_peer_id and record.pending_drop then
		local drop_fields = record.pending_drop
		drop_fields[3] = incarnation
		drop_fields[4] = generation
		record.pending_drop = nil
		send(runtime.host_peer_id, drop_fields)
	elseif holder == runtime.local_peer_id and record.pending_clear then
		send(runtime.host_peer_id, head("clear", record))
		finish_local(record)
	end
	return true
end

function M:retry_pending_held()
	local runtime = get_runtime()
	if not next(self.pending_held) then
		return
	end
	for holder, pending in pairs(self.pending_held) do
		local bag = runtime:target_identity("bag", pending.id)
		if not bag or bag.unit ~= pending.unit or not alive(bag.unit) then
			self.pending_held[holder] = nil
		elseif bag.incarnation == pending.incarnation then
			receive_held(self, pending.fields, pending.id, pending.incarnation, pending.generation, holder)
			local held = retained.held[holder]
			if
				held
				and held.unit == pending.unit
				and held.incarnation == pending.incarnation
				and held.generation == pending.generation
			then
				self.pending_held[holder] = nil
			end
		elseif bag.incarnation ~= 0 then
			self.pending_held[holder] = nil
		end
	end
end

local function receive_denial(self, id, incarnation, generation, holder)
	local runtime = get_runtime()
	local record = find_local(id, incarnation, generation)
	if not record or holder ~= runtime.local_peer_id then
		return false
	end
	local current = session()
	local local_peer = current and current:local_peer()
	if not local_peer then
		return false
	end
	local data = Unit.carry(record.unit)
	if not data then
		return false
	end
	Unit.cancel_teleport(data)
	if not Unit.set_hidden(record, local_peer:unit()) then
		return false
	end
	record.pending_drop = nil
	if record.prediction then
		runtime:cancel_prediction_for_unit(record.unit, "native_drop_rejected")
		record.prediction = nil
	end
	record.held = true
	for index = #self.skips, 1, -1 do
		local marker = self.skips[index]
		if marker.record == record then
			table.remove(self.skips, index)
		end
	end
	local inventory = record.inventory
	local pm = managers.player
	if inventory and pm and pm.set_carry and (not pm.get_my_carry_data or not pm:get_my_carry_data()) then
		pm:set_carry(
			inventory.carry_id,
			inventory.multiplier,
			inventory.dye_initiated,
			inventory.has_dye_pack,
			inventory.dye_value_multiplier
		)
	end
	return true
end

local function receive_terminal(self, id, incarnation, generation, holder)
	local runtime = get_runtime()
	local queued = self.pending_held[holder]
	if queued and generation >= queued.generation then
		self.pending_held[holder] = nil
	end
	local bag = resolve(id, incarnation)
	if bag then
		self.observer_pickups[bag.unit] = nil
	end
	local record = holder == runtime.local_peer_id and find_local(id, incarnation, generation) or retained.held[holder]
	if record and record.id == id and record.incarnation == incarnation and record.generation == generation then
		record.held = false
		if not record.pipeline or not newer_local(record) then
			Unit.reveal(record)
		end
		remember(record)
		if holder == runtime.local_peer_id then
			finish_local(record)
		else
			retained.held[holder] = nil
		end
	end
	retained.remember_head(id, incarnation, generation, holder)
	return true
end

function M:receive(fields, id, incarnation, generation, holder)
	local op = fields[1]
	if op == "held" and #fields == 5 then
		return receive_held(self, fields, id, incarnation, generation, holder)
	elseif op == "dropdeny" and #fields == 5 then
		return receive_denial(self, id, incarnation, generation, holder)
	elseif op == "release" and #fields == 5 then
		return receive_terminal(self, id, incarnation, generation, holder)
	end
	return false
end

function M:unit_destroyed(unit)
	self.observer_pickups[unit] = nil
	for holder, pending in pairs(self.pending_held) do
		if pending.unit == unit then
			self.pending_held[holder] = nil
		end
	end
	for _, record in ipairs(local_records()) do
		if record.unit == unit and record.pipeline then
			finish_local(record)
		end
	end
	if self.local_record and self.local_record.unit == unit then
		local record = self.local_record
		local can_resume_drop = record.pending_drop and self:can_finish_drop(record.inventory)
		self.pending, self.local_record = nil, nil
		if not Network:is_server() and can_resume_drop then
			local fields = record.pending_drop
			local position = Vector3(fields[7], fields[8], fields[9])
			local rotation = Rotation(fields[10], fields[11], fields[12])
			local direction = Vector3(fields[13], fields[14], fields[15])
			carry_requests:resume_drop(
				record.inventory,
				position,
				rotation,
				direction,
				fields[16],
				record.native_approved
			)
		end
	end
	for index = #self.skips, 1, -1 do
		if self.skips[index].unit == unit then
			table.remove(self.skips, index)
		end
	end
end

function M:peer_lost(id)
	self.pending_held[id] = nil
	local record = retained.held[id]
	if not record then
		return false
	end
	Unit.reveal(record)
	retained.retire(record)
	return true
end

function M:reset(preserve_drop_ordinals)
	local local_record = self.local_record
	self.pending, self.local_record = nil, nil
	self.inflight, self.observer_pickups, self.pending_held, self.skips = {}, {}, {}, {}
	if not preserve_drop_ordinals then
		self.next_prediction_token = 0
	end
	return local_record
end

function M:interaction_started(unit)
	if Network:is_server() then
		return false
	end
	if not control.allows_new_work("bag_handling") then
		self:archive_drop()
		return false
	end
	if self:begin_pickup(unit) then
		return true, false
	end
	local native_pickup = carry_requests:begin_pickup(unit:carry_data():carry_id(), unit)
	if native_pickup then
		self:archive_drop()
	end
	return true, native_pickup
end

function M:interaction_finished(unit, native_pickup, result)
	if native_pickup then
		carry_requests:finish_pickup(result)
	else
		self:finish_pickup(unit, result)
	end
end

function M:corpse_pickup_started(unit)
	if not control.allows_new_work("bag_handling") or managers.player:current_carry_id() ~= nil then
		return false
	end
	local corpse = managers.enemy:get_corpse_unit_data_from_key(unit:key())
	local predicting = carry_requests:begin_pickup("person", unit, corpse and corpse.u_id)
	if predicting then
		self:archive_drop()
	end
	return predicting
end

function M:corpse_pickup_finished()
	carry_requests:finish_pickup(managers.player:current_carry_id() == "person")
end

function M:small_loot_taken(base)
	if Network:is_server() or base.skip_remove_unit or not control.allows_new_work("bag_handling") then
		return
	end
	base._unit:set_visible(false)
end

function M:observe_retained_pickup(interaction, peer, player)
	local unit = interaction._unit
	local holder = peer and peer:id()
	if not retained.preserve_pickup(unit, holder) then
		return false
	end
	self:begin_observer_pickup(unit, holder)
	local no_player = player == nil
	player = player or peer:unit()
	if peer and not managers.player:register_carry(peer, unit:carry_data():carry_id()) then
		self:finish_observer_pickup(unit)
		return true
	end
	if interaction._global_event then
		managers.mission:call_global_event(interaction._global_event, player)
	end
	if no_player then
		managers.mission:call_global_event("on_picked_up_carry", unit)
	end
	self:finish_observer_pickup(unit)
	return true
end

return M
