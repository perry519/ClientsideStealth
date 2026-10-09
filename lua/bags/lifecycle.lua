local M, retained, host, client, carry_requests, Unit, Records, get_runtime, control, world_target, get_preview, secure_host, secure_client =
	...
M.pending_loaded = setmetatable({}, { __mode = "k" })

function M:busy_for_pause(local_only)
	return client:busy_for_pause(local_only)
		or not local_only and next(retained.held) ~= nil
		or carry_requests:busy_for_pause()
end

function M:receive_record(sender, fields)
	local runtime = get_runtime()
	if type(fields) ~= "table" then
		return false
	end
	if fields[1] == "secure" then
		return secure_host:receive(sender, fields)
	elseif fields[1] == "secure_ack" then
		return secure_client:receive(sender, fields)
	end
	local header = Records.numeric(fields, 2, 5, 2147483647, true)
	if not header then
		return false
	end
	local id, incarnation, generation, holder = header[1], header[2], header[3], header[4]
	if Network:is_server() then
		return host:receive(sender, fields, id, incarnation, generation, holder)
	end
	if sender ~= runtime.host_peer_id then
		return false
	end
	return client:receive(fields, id, incarnation, generation, holder)
end

function M:retry_pending_held()
	for unit in pairs(self.pending_loaded) do
		if not alive(unit) or self:spawned(unit) then
			self.pending_loaded[unit] = nil
		end
	end
	return client:retry_pending_held()
end

function M:reset(preserve_drop_ordinals)
	self.pending_loaded = setmetatable({}, { __mode = "k" })
	carry_requests:reset(preserve_drop_ordinals)
	local local_record = client:reset(preserve_drop_ordinals)
	secure_host:reset()
	secure_client:reset()
	retained.reset()
	Unit.rollback(local_record)
	host:reset()
end

function M:unit_destroyed(unit)
	secure_host:invalidate(unit)
	host:unit_destroyed(unit)
	client:unit_destroyed(unit)
	for _, record in pairs(retained.held) do
		if record.unit == unit then
			retained.retire(record)
		end
	end
end

function M:picked_up(unit)
	secure_host:invalidate(unit)
	get_preview():prepare_pickup(unit)
end

function M:peer_added()
	if not Network:is_server() then
		return false
	end
	return host:peer_added()
end

function M:peer_lost(id)
	secure_host:peer_lost(id)
	carry_requests:peer_lost(id)
	if Network:is_server() then
		return host:peer_lost(id)
	end
	if id == get_runtime().host_peer_id then
		self:reset()
		return true
	end
	return client:peer_lost(id)
end

local function target_id(unit)
	local id = unit and unit:id()

	return id ~= -1 and id or nil
end

function M:spawned(unit)
	local id = target_id(unit)
	if id then
		return world_target.register("bag", id, unit)
	end
end

function M:loaded(unit)
	if not self:spawned(unit) then
		self.pending_loaded[unit] = true
	end
end

function M:thrown(unit, peer_id)
	local id = target_id(unit)
	if id then
		local target = world_target.register("bag", id, unit, peer_id)
		if target then
			self.pending_loaded[unit] = nil
		end
	end
end

function M:destroyed(unit)
	self.pending_loaded[unit] = nil
	self:unit_destroyed(unit)
	if target_id(unit) then
		world_target.unregister_unit(unit)
	end
end

function M:secured(unit)
	secure_host:invalidate(unit, true)
	get_preview():native_secured(unit)
	if target_id(unit) then
		world_target.unregister_unit(unit)
	end
end

function M:drop(data, position, rotation, direction, upgrade, zipline)
	local record = client.local_record
	local predicted, mode = client:predict_drop(data, position, rotation, direction, upgrade, zipline)
	if mode == "drop_pending" then
		return "pending"
	end
	if predicted and record then
		get_preview():watch(record.unit, record.carry_id, record.prediction_token)
	end
	if not predicted then
		local preview = get_preview()
		local preview_created = control.allows_new_work("bag_handling")
			and preview:predict(data, position, rotation, direction, upgrade, zipline)
		local requested = carry_requests:request_drop(data, position, rotation, direction, upgrade, zipline)
		if not requested then
			if preview_created then
				preview:reject(data.carry_id)
			end
			return nil
		end
	end
	return "dropped"
end

function M:host_drop(manager, args, native, ...)
	local peer = args[11]
	local peer_id = peer and peer:id()
	local native_key = Network:is_server() and carry_requests:receiving_token(peer_id)
	local handled, unit = host:server_drop(manager, args)
	if not handled then
		unit = native(manager, ...)
	end
	if native_key and alive(unit) then
		local config = world_target.config(unit)
		if config then
			host.confirm_drop(unit, unit:id(), peer_id, peer:unit(), native_key, config)
		end
	end
	return unit
end

return M
