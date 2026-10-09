local adapters, receive, preference, loaded_schema, epoch = ...

local HOST = 1

local RETRY = 1

local SPAN = 100000
local EPOCHS = 9999
local BASE = (((epoch or 1) - 1) % EPOCHS + 1) * SPAN
local T = { peers = {}, now = 0, gen = BASE, attempts = BASE, channel = adapters.channel }

T.restart_required = loaded_schema ~= nil and loaded_schema ~= adapters.rpc.schema or nil

function T:offer()
	return self.preference == "rpc" and "2:rpc:" .. adapters.rpc.schema or "2:lua"
end

function T:prefer(mode)
	local offer = self.preference and self:offer()
	self.preference = self.restart_required and "lua" or mode
	if self:offer() ~= offer then
		self.gen = self.gen + 1
	end
end
T:prefer(preference or "rpc")

function T:available()
	return true
end
function T:reset(current)
	self.session, self.peers = current, {}
end
function T:peer(id)
	local current = adapters.session()
	if current ~= self.session then
		self:reset(current)
	end
	self.peers[id] = self.peers[id] or {}
	return self.peers[id], current and current.peer and current:peer(id)
end

function T:mode(id)
	local state = adapters.session() == self.session and self.peers[id]
	return state and state.mode or nil
end
function T:forget(id)
	self.peers[id] = nil
end

function T:use_roster(roster)
	self.roster = roster
end

local function host_link(id)
	return adapters.is_server() or id == HOST
end

local function initiates(id)
	return id < adapters.local_id()
end

local function linked(self, id, state)
	return host_link(id)
		or self.roster ~= nil and state.membership ~= nil and state.membership == self.roster.membership(id)
end

local function identity(self, id)
	if host_link(id) then
		return 0, 0, 0
	end
	local roster = self.roster
	return roster.session_id() or 0, roster.membership(adapters.local_id()) or 0, roster.membership(id) or 0
end

local function identified(self, id, session, sender, ours)
	local current, mine, theirs = identity(self, id)
	return session == current and sender == theirs and ours == mine
end

local function labelled(self, id, body)
	local session, mine, theirs = identity(self, id)
	return body .. ":" .. session .. ":" .. mine .. ":" .. theirs
end

local function epoch_of(id)
	return math.floor(id / SPAN)
end

local function newer(id, last)
	if last == nil then
		return true
	end

	local step = (epoch_of(id) - epoch_of(last)) % EPOCHS
	if step == 0 then
		return id > last
	end
	return step <= EPOCHS / 2
end

local function target(self, state)
	return state.remote and (self.preference == "rpc" and state.remote == self:offer() and "rpc" or "lua")
end

local function advertise(self, id, state)
	local remote_gen = state.remote_gen or 0
	if
		state.advertised == self.gen
		and state.acked == remote_gen
		and (state.seen == self.gen or self.now < (state.offer_at or -math.huge))
	then
		return true
	end
	if not adapters.control(id, labelled(self, id, self:offer() .. ":" .. self.gen .. ":" .. remote_gen)) then
		return false
	end
	state.advertised, state.acked, state.offer_at = self.gen, remote_gen, self.now + RETRY
	return true
end

local function settle(self, id, state, peer, ready)
	if not advertise(self, id, state) or not initiates(id) then
		return
	end
	local want = target(self, state)
	if not want or want == state.mode and not state.attempt then
		return
	end
	local attempt = state.attempt
	if not attempt or attempt.mode ~= want then
		if state.mode and not ready(id) then
			return
		end
		self.attempts = self.attempts + 1
		attempt = { id = self.attempts, mode = want }
		state.attempt, state.retry_at = attempt, nil
		state.rpc = state.rpc or want == "rpc" or nil
	end
	if self.now >= (state.retry_at or -math.huge) then
		state.retry_at = self.now + RETRY
		if want == "rpc" then
			adapters.handshake(peer, "cst_rpc_v1_ping", attempt.id, identity(self, id))
		else
			adapters.control(id, labelled(self, id, "s:" .. attempt.id))
		end
	end
end

local function always()
	return true
end

local function follow_roster(self, now)
	local roster = self.roster
	for id, state in pairs(self.peers) do
		if state.membership and (not roster or roster.membership(id) ~= state.membership) then
			self.peers[id] = nil
		end
	end
	if not roster or adapters.is_server() then
		return
	end
	for id in roster.members() do
		if id ~= HOST then
			local membership = roster.membership(id)
			local state = self.peers[id]
			if not state or state.membership ~= membership then
				state = { membership = membership }
				self.peers[id] = state
			end
			if not state.remote and now >= (state.offer_at or -math.huge) then
				state.advertised = nil
				advertise(self, id, state)
			end
		end
	end
end

function T:update(now, ready)
	self.now = now
	local session = adapters.session()
	if session ~= self.session then
		self:reset(session)
	end
	if not session or not session.peer then
		return
	end
	follow_roster(self, now)
	for id, state in pairs(self.peers) do
		local peer = session:peer(id)
		if peer and (state.remote or state.advertised) then
			settle(self, id, state, peer, ready or always)
		end
	end
end

function T:switch_wanted(id)
	local state = adapters.session() == self.session and self.peers[id]
	if not state or not state.mode or not initiates(id) then
		return false
	end
	local want = target(self, state)
	return state.attempt ~= nil or want ~= nil and want ~= false and want ~= state.mode
end

function T:direct_ready(id)
	return self:mode(id) ~= nil and not self:switch_wanted(id)
end

function T:settling()
	if adapters.session() ~= self.session then
		return false
	end
	for _, state in pairs(self.peers) do
		local want = target(self, state)
		if state.mode and (state.attempt or state.advertised ~= self.gen or want and want ~= state.mode) then
			return true
		end
	end
	return false
end

function T:start(id)
	local state = self:peer(id)
	if not state.mode then
		state.advertised = nil
		advertise(self, id, state)
	end
	return self.preference == "lua" or state.mode ~= nil
end

local function confirm(state, attempt_id)
	local attempt = state.attempt
	if attempt and attempt.id == attempt_id then
		state.mode, state.attempt = attempt.mode, nil
	end
end

local function apply(state, attempt_id, mode)
	if attempt_id == state.applied or newer(attempt_id, state.applied) then
		state.applied, state.mode = attempt_id, mode
		return true
	end
	return false
end

function T:capability(id, body)
	if type(body) ~= "string" or #body > 64 then
		return false
	end
	local kind, attempt_id, session, sender, ours = body:match("^([sd]):(%d+):(%d+):(%d+):(%d+)$")
	local offer, gen, seen
	if not kind then
		offer, gen, seen, session, sender, ours = body:match("^(2:lua):(%d+):(%d+):(%d+):(%d+):(%d+)$")
		if not offer then
			offer, gen, seen, session, sender, ours = body:match("^(2:rpc:%w+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
		end
	end
	attempt_id, gen, seen = tonumber(attempt_id), tonumber(gen), tonumber(seen)
	if not attempt_id and not offer then
		return false
	end
	local state, peer = self:peer(id)
	if
		not peer
		or not linked(self, id, state)
		or not identified(self, id, tonumber(session), tonumber(sender), tonumber(ours))
	then
		return false
	end
	if attempt_id then
		local initiator = initiates(id)
		if kind == "s" and not initiator and apply(state, attempt_id, "lua") then
			adapters.control(id, labelled(self, id, "d:" .. attempt_id))
		elseif kind == "d" and initiator then
			confirm(state, attempt_id)
		end
		return true
	end

	if newer(gen, state.remote_gen) then
		if state.remote_gen and epoch_of(gen) ~= epoch_of(state.remote_gen) then
			state.advertised = nil
		end
		state.remote, state.remote_gen = offer, gen
	end

	state.seen = seen
	if seen ~= self.gen then
		state.advertised = nil
	end

	if not state.mode then
		settle(self, id, state, peer, always)
	else
		advertise(self, id, state)
	end
	return true
end

function T:handshake(id, message, version, attempt_id, session, sender, ours)
	local state, peer = self:peer(id)
	if
		version ~= 1
		or type(attempt_id) ~= "number"
		or not peer
		or not linked(self, id, state)
		or not identified(self, id, session, sender, ours)
	then
		return false
	end
	if message == "cst_rpc_v1_ping" then
		if initiates(id) or target(self, state) ~= "rpc" or not apply(state, attempt_id, "rpc") then
			return false
		end
		state.rpc = true
		adapters.handshake(peer, "cst_rpc_v1_ack", attempt_id, identity(self, id))
	elseif message == "cst_rpc_v1_ack" and initiates(id) then
		confirm(state, attempt_id)
	end
	return true
end

function T:send(id, channel, record)
	local state, peer = self:peer(id)
	local mode = state.mode or (self.preference == "lua" and not state.membership and "lua")
	if not mode then
		return false, "transport_not_ready"
	end
	local sent, reason = adapters[mode].send(id, peer, channel, record)
	if not sent then
		return false, reason
	end
	return true
end

local function accepts(state, backend)
	return backend == "lua" or state.mode == "rpc" or state.rpc == true
end
function T:receive_lua(id, message, body)
	if message == "cst_rpc_v1_cap" then
		return self:capability(id, body)
	end
	local state = self:peer(id)
	if message == T.channel.hello and not state.mode and not state.remote then
		state.mode = "lua"
	end
	local channel, record = adapters.lua.decode(message, body)
	if not channel then
		return false, record
	end
	return receive(id, channel, record)
end
function T:receive_rpc(id, name, args)
	if name == "cst_rpc_v1_ping" or name == "cst_rpc_v1_ack" then
		return self:handshake(id, name, args[1], args[2], args[3], args[4], args[5])
	end
	if not accepts(self:peer(id), "rpc") then
		return false
	end
	local channel, record = adapters.rpc.decode(name, args)
	if not channel then
		return false
	end
	return receive(id, channel, record)
end
return T
