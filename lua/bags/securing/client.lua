local retained, Records, Unit, get_runtime, control, peers = ...
local M = {}
local pending = {}
local TIMEOUT = 10
local RETRY = 0.5
local MAX_PENDING = 8

local function now()
	return TimerManager:wall():time()
end

function M:report(token, contact, unit)
	local runtime = get_runtime()
	local session, membership = peers.session_id(), peers.membership(runtime.local_peer_id)
	if
		Network:is_server()
		or not control.allows_new_work("bag_secure")
		or not Records.throw_token(token, runtime.local_peer_id)
		or not runtime:is_peer_capable(runtime.host_peer_id)
		or not session
		or not membership
	then
		return nil
	end
	if pending[token] then
		return pending[token]
	end
	local count = 0
	for _ in pairs(pending) do
		count = count + 1
	end
	if count >= MAX_PENDING then
		return nil
	end
	local position = contact.position
	local fields = {
		"secure",
		token,
		contact.area_id,
		Unit.scalar(position, "x"),
		Unit.scalar(position, "y"),
		Unit.scalar(position, "z"),
		session,
		membership,
	}
	if not Records.secure(fields) then
		return nil
	end
	local time = now()
	local request = { fields = fields, unit = unit, expires = time + TIMEOUT, retry_at = time + RETRY }
	pending[token] = request
	retained.send(runtime.host_peer_id, fields)
	return request
end

function M:receive(sender, fields)
	local token, status, session, membership = Records.secure_ack(fields)
	local runtime = get_runtime()
	if
		Network:is_server()
		or sender ~= runtime.host_peer_id
		or not token
		or peers.session_id() ~= session
		or peers.membership(runtime.local_peer_id) ~= membership
	then
		return false
	end
	local request = pending[token]
	if not request or request.fields[7] ~= session or request.fields[8] ~= membership then
		return false
	end
	request.status = status
	pending[token] = nil
	return true
end

function M:cancel(unit)
	for token, request in pairs(pending) do
		if request.unit == unit then
			request.status = 0
			pending[token] = nil
		end
	end
end

function M:update(time)
	local runtime = get_runtime()
	for token, request in pairs(pending) do
		if
			time >= request.expires
			or not runtime:is_peer_capable(runtime.host_peer_id)
			or request.fields[7] ~= peers.session_id()
			or request.fields[8] ~= peers.membership(runtime.local_peer_id)
		then
			request.status = 0
			pending[token] = nil
		elseif time >= request.retry_at then
			request.retry_at = time + RETRY
			retained.send(runtime.host_peer_id, request.fields)
		end
	end
end

function M:reset()
	for _, request in pairs(pending) do
		request.status = 0
	end
	pending = {}
end

return M
