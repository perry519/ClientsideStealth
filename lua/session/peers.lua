local get_runtime, control, features, settings = ...
local peers = {}
local COUNT = #settings.FEATURES
local NONE = string.rep("0", COUNT)
local INDEX = {}
for index, name in ipairs(settings.FEATURES) do
	INDEX[name] = index
end
local RETRY = 1
local LIMIT = 1000000000

local state

local issued

local floor = {}

function peers.reset()
	state = {

		session_id = nil,
		rev = 0,
		next_membership = 0,

		entries = {},

		pending = {},
		signature = nil,
	}
end
peers.reset()

local function is_host()
	return get_runtime():is_host()
end

local function session_id()
	if not state.session_id then
		issued = (issued or math.random(1, 400000000)) + 1
		state.session_id = issued
	end
	return state.session_id
end

function peers.session_id()
	return state.session_id
end

function peers.rev()
	return state.rev
end

function peers.membership(peer_id)
	local entry = state.entries[peer_id]
	return entry and entry.membership or nil
end

function peers.effective(peer_id)
	local mask = is_host() and features.effective(peer_id) or nil
	if not mask then
		local entry = state.entries[peer_id]
		mask = entry and entry.mask
	end
	return mask
end

function peers.allows(peer_id, name)
	local index = assert(INDEX[name], "ClientsideStealth: unknown feature " .. tostring(name))
	local mask = peers.effective(peer_id)
	return mask ~= nil and mask:sub(index, index) == "1"
end

function peers.members()
	local local_id = get_runtime().local_peer_id
	local id
	return function()
		repeat
			id = next(state.entries, id)
		until id == nil or id ~= local_id
		return id
	end
end

function peers.join(peer_id)
	if not is_host() then
		return nil
	end
	local entry = state.entries[peer_id]
	if not entry then
		state.next_membership = state.next_membership + 1
		entry = { membership = state.next_membership, mask = NONE }
		state.entries[peer_id] = entry
	end
	session_id()
	return entry.membership
end

function peers.peer_lost(peer_id)
	if not is_host() and peer_id == get_runtime().host_peer_id then
		peers.reset()
		floor = {}
		return
	end
	state.entries[peer_id], state.pending[peer_id] = nil, nil
end

local function body()
	local parts = {}
	for id, entry in pairs(state.entries) do
		parts[#parts + 1] = id .. "." .. entry.membership .. "." .. entry.mask
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function refresh(runtime)
	local session = runtime:session()
	if not session then
		return
	end
	peers.join(runtime.local_peer_id)
	for id in pairs(session:peers()) do
		if features.effective(id) and not state.entries[id] then
			peers.join(id)
		end
	end
	for id, entry in pairs(state.entries) do
		entry.mask = features.effective(id) or NONE
	end
	local signature = body()
	if signature ~= state.signature then
		state.signature, state.rev = signature, state.rev + 1
		for id in pairs(state.entries) do
			if id ~= runtime.local_peer_id then
				state.pending[id] = 0
			end
		end
	end
end

local function ack()
	control.send(get_runtime().host_peer_id, control.ACK, "r:" .. state.rev .. ":" .. (state.session_id or 0))
end

function peers.update(now)
	local runtime = get_runtime()
	if not runtime:session() then
		return
	end
	if not is_host() then
		if not state.session_id and now >= (state.request_at or 0) then
			state.request_at = now + RETRY
			ack()
		end
		return
	end
	refresh(runtime)
	for id, retry in pairs(state.pending) do
		if now >= retry then
			state.pending[id] = now + RETRY
			control.send(id, control.CHANNEL, "r:" .. state.rev .. ":" .. session_id() .. ":" .. state.signature)
		end
	end
end

local function parse_number(text)
	local value = tonumber(text)
	return value and value >= 0 and value <= LIMIT and value or nil
end

function peers.receive(sender, body_text)
	local runtime = get_runtime()
	if is_host() or sender ~= runtime.host_peer_id or not runtime:session() or type(body_text) ~= "string" then
		return false
	end
	local rev, session, entries_text = body_text:match("^r:(%d+):(%d+):(.*)$")
	rev, session = parse_number(rev), parse_number(session)
	if not rev or not session or session == 0 then
		return false
	end
	local entries = {}
	for part in (entries_text .. ","):gmatch("([^,]*),") do
		local id, membership, mask = part:match("^(%d+)%.(%d+)%.([01]+)$")
		id, membership = parse_number(id), parse_number(membership)
		if not id or not membership or membership == 0 or #mask ~= COUNT or entries[id] then
			return false
		end
		entries[id] = { membership = membership, mask = mask }
	end
	local connection = runtime:session()
	if floor.connection ~= connection then
		floor = { connection = connection, session = 0, rev = 0 }
	end
	if session > floor.session or session == floor.session and rev > floor.rev then
		state.session_id, state.rev, state.entries = session, rev, entries
		floor.session, floor.rev = session, rev
	end
	ack()
	return true
end

function peers.receive_ack(sender, body_text)
	if not is_host() or type(body_text) ~= "string" then
		return false
	end
	local rev, session = body_text:match("^r:(%d+):(%d+)$")
	rev, session = parse_number(rev), parse_number(session)
	if not rev or not session then
		return false
	end
	if rev == state.rev and session == state.session_id then
		state.pending[sender] = nil
	elseif session == 0 and state.entries[sender] and state.session_id then
		state.rev = state.rev + 1
		for id in pairs(state.entries) do
			if id ~= get_runtime().local_peer_id then
				state.pending[id] = 0
			end
		end
	elseif state.entries[sender] then
		state.pending[sender] = state.pending[sender] or 0
	end
	return true
end

return peers
