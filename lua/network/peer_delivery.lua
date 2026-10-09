local get_runtime, transport, peers, Codec, Channel, log_event = ...
local D = { families = {} }

local CAP = { streams = 256 }
D.CAP = CAP
local ENVELOPE = {}
for _, field in ipairs(Codec.PEER_ENVELOPE) do
	ENVELOPE[field[1]] = true
end

local function prefixed(key, prefix)
	return key:sub(1, #prefix) == prefix
end

local function drop(entries, prefix)
	local dropped = false
	for key in pairs(entries) do
		if prefixed(key, prefix) then
			entries[key], dropped = nil, true
		end
	end
	return dropped
end

local function make_room(entries, prefix, cap, now)
	local total, oldest_key, oldest = 0, nil, nil
	for key, entry in pairs(entries) do
		if prefixed(key, prefix) then
			if now >= entry.expires then
				entries[key] = nil
			else
				total = total + 1
				if not oldest or entry.expires < oldest then
					oldest_key, oldest = key, entry.expires
				end
			end
		end
	end
	if total >= cap then
		entries[oldest_key] = nil
	end
end

local function clear(self)
	self.now = self.now or 0
	self.session = peers.session_id()

	self.streams = {}
end
clear(D)

local function base_of(env)
	return env.family .. "|" .. env.session_id .. ":" .. env.membership .. "|" .. env.key
end

local function eligible(id, spec)
	return peers.allows(id, spec.feature)
end

function D:register(family, spec)
	assert(not self.families[family], "ClientsideStealth: peer family registered twice: " .. tostring(family))
	assert(type(spec.feature) == "string" and type(spec.validate) == "function" and type(spec.apply) == "function")
	assert(type(spec.lifetime) == "number" and spec.lifetime > 0, "ClientsideStealth: peer family lifetime")
	for _, field in ipairs(spec.fields) do
		assert(not ENVELOPE[field[1]], "ClientsideStealth: peer field shadows the envelope: " .. field[1])
	end
	Codec.define_peer_family(family, spec.fields)
	self.families[family] = spec
end

local function envelope(spec, family, actor, key, version, op, record)
	local env = {
		family = family,
		session_id = peers.session_id(),
		actor = actor,
		membership = peers.membership(actor),
		key = key,
		version = version,
		op = op,
	}
	for _, field in ipairs(spec.fields) do
		env[field[1]] = record[field[1]]
	end
	return env
end

function D:propose(family, key, version, record)
	local spec = assert(self.families[family], "ClientsideStealth: unknown peer family " .. tostring(family))
	local runtime = get_runtime()
	local actor = runtime.local_peer_id
	if runtime:is_host() or not peers.membership(actor) or not eligible(actor, spec) then
		return nil, "not_member"
	end
	local env = envelope(spec, family, actor, key, version, "set", record)
	local body, reason = Codec.encode_peer(env)
	if not body then
		return nil, reason
	end
	local unreached = false
	for peer_id in peers.members() do
		if peer_id ~= actor and peer_id ~= runtime.host_peer_id and eligible(peer_id, spec) then
			if transport:direct_ready(peer_id) then
				transport:send(peer_id, Channel.peer, env)
			else
				unreached = true
			end
		end
	end
	if unreached then
		transport:send(runtime.host_peer_id, Channel.peer, env)
	elseif eligible(runtime.host_peer_id, spec) then
		transport:send(runtime.host_peer_id, Channel.peer, envelope(spec, family, actor, key, version, "view", record))
	end
	return env
end

local function forward(spec, actor, env)
	for peer_id in peers.members() do
		if peer_id ~= actor and peer_id ~= get_runtime().local_peer_id and eligible(peer_id, spec) then
			transport:send(peer_id, Channel.peer_relay, env)
		end
	end
end

function D:retract(family, actor, key, version, record)
	local spec = assert(self.families[family], "ClientsideStealth: unknown peer family " .. tostring(family))
	if not get_runtime():is_host() or not peers.membership(actor) then
		return nil
	end
	local env = envelope(spec, family, actor, key, version, "reject", record)
	forward(spec, actor, env)
	return env
end

function D:receive(sender, channel, record)
	local runtime = get_runtime()
	local is_host = runtime:is_host()
	local spec = type(record) == "table" and self.families[record.family]
	if not spec or record.session_id ~= peers.session_id() or is_host and channel ~= Channel.peer then
		return false
	end
	local env, body = {}, {}
	for name in pairs(ENVELOPE) do
		env[name] = record[name]
	end
	for _, field in ipairs(spec.fields) do
		body[field[1]] = record[field[1]]
	end

	if channel == Channel.peer then
		if
			sender ~= env.actor
			or sender == runtime.host_peer_id
			or env.op ~= "set" and not (is_host and env.op == "view")
		then
			return false
		end
	elseif
		channel ~= Channel.peer_relay
		or sender ~= runtime.host_peer_id
		or env.op ~= "set" and env.op ~= "reject"
	then
		return false
	end
	if
		peers.membership(env.actor) ~= env.membership
		or not eligible(env.actor, spec)
		or not eligible(runtime.local_peer_id, spec)
	then
		return false
	end
	local validated, reason = spec.validate(body, env)
	if not validated then
		log_event(
			"peer_delivery_rejected",
			{ "family", env.family, "actor", env.actor, "key", env.key, "reason", reason }
		)
		return false
	end
	if is_host and env.op == "set" then
		forward(spec, env.actor, record)
	end
	local route = channel == Channel.peer and "direct" or "relay"
	if env.op == "reject" then
		spec.apply(env, validated, route)
		return true
	end
	local base = base_of(env)
	local stream = self.streams[base]
	if stream and stream.version >= env.version then
		return true
	end

	if spec.apply(env, validated, route) == false then
		return false
	end
	if not stream then
		make_room(
			self.streams,
			env.family .. "|" .. env.session_id .. ":" .. env.membership .. "|",
			CAP.streams,
			self.now
		)
		stream = {}
		self.streams[base] = stream
	end
	stream.version, stream.expires = env.version, self.now + 2 * spec.lifetime
	return true
end

function D:reset()
	clear(self)
	for _, spec in pairs(self.families) do
		if spec.reset then
			spec.reset()
		end
	end
end

function D:peer_lost(peer_id)
	local runtime = get_runtime()
	if not runtime:is_host() and peer_id == runtime.host_peer_id then
		self:reset()
	end
end

local function follow_roster(self, local_id)
	if peers.session_id() ~= self.session then
		self:reset()
		return
	end
	for family, spec in pairs(self.families) do
		if not eligible(local_id, spec) and drop(self.streams, family .. "|") and spec.reset then
			spec.reset()
		end
	end
end

function D:update(now)
	self.now = now
	local runtime = get_runtime()
	if not runtime.current_session or not peers.session_id() then
		return
	end
	follow_roster(self, runtime.local_peer_id)
	for key, stream in pairs(self.streams) do
		if now >= stream.expires then
			self.streams[key] = nil
		end
	end
end

return D
