local retained, Records, get_runtime, control, areas, peers = ...
local M = {}
local throws, units = {}, {}
local LIFETIME = 30
local MAX_THROWS = 64

local function now()
	return TimerManager:wall():time()
end

local function forget(token)
	local record = throws[token]
	if units[record.unit] == record then
		units[record.unit] = nil
	end
	throws[token] = nil
end

function M:invalidate(unit, secured)
	local record = units[unit]
	if record then
		if record.status == nil then
			record.status = secured and 1 or 0
		end
		units[unit] = nil
	end
end

function M:track(unit, peer, token)
	local runtime = get_runtime()
	if not Network:is_server() or not Records.throw_token(token, peer) then
		return
	end
	self:invalidate(unit)
	if not runtime:is_peer_capable(peer) or not control.allows_new_work("bag_secure", peer) then
		return
	end
	local identity = retained.target(unit)
	local data = alive(unit) and unit:carry_data()
	local session, membership = peers.session_id(), peers.membership(peer)
	if not identity or not data or not session or not membership then
		return
	end
	local time, count, oldest = now(), 0
	for key, record in pairs(throws) do
		if time >= record.expires then
			forget(key)
		else
			count = count + 1
			if not oldest or record.expires < throws[oldest].expires then
				oldest = key
			end
		end
	end
	if count >= MAX_THROWS then
		forget(oldest)
	end
	local record = {
		unit = unit,
		peer = peer,
		session = session,
		membership = membership,
		id = identity.id,
		incarnation = identity.incarnation,
		generation = data._cst_bag_generation,
		carry_id = data:carry_id(),
		expires = time + LIFETIME,
	}
	throws[token], units[unit] = record, record
end

function M:receive(sender, fields)
	local token, area, position, session, membership = Records.secure(fields)
	local runtime = get_runtime()
	if
		not Network:is_server()
		or not token
		or not Records.throw_token(token, sender)
		or not runtime:is_peer_capable(sender)
		or peers.session_id() ~= session
		or peers.membership(sender) ~= membership
	then
		return false
	end
	local record = throws[token]
	if
		not record
		or record.peer ~= sender
		or record.session ~= session
		or record.membership ~= membership
		or now() >= record.expires
	then
		return false
	end
	if record.status == nil and not record.committed then
		local unit = record.unit
		local identity = retained.resolve(record.id, record.incarnation)
		local data = alive(unit) and unit:carry_data()
		local valid = identity
			and identity.unit == unit
			and units[unit] == record
			and not retained.holding(unit)
			and data
			and data._cst_bag_generation == record.generation
			and data:latest_peer_id() == sender
			and data:carry_id() == record.carry_id
			and data:value() > 0
			and not data:is_linked_to_unit()
		record.committed = true
		if not (valid and areas.commit(area, Vector3(position[1], position[2], position[3]), unit)) then
			record.status = record.status or 0
			if units[unit] == record then
				units[unit] = nil
			end
		end
	end
	if record.status == nil then
		return false
	end
	retained.send(sender, { "secure_ack", token, record.status, session, membership })
	return record.status == 1
end

function M:peer_lost(peer)
	for token, record in pairs(throws) do
		if record.peer == peer then
			forget(token)
		end
	end
end

function M:reset()
	throws, units = {}, {}
end

return M
