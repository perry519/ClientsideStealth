local get_runtime, adapters, features, transport, Records = ...

local M = { incoming = {}, outgoing = {}, sent = {}, owed = {} }
local CHANNEL = transport.channel.camera_hud
local LIMIT = 1024

M.RECOVERY = 0.5

local object_key = Records.object_key

local function record_key(record)
	return tostring(record.observer_id)
		.. ":"
		.. tostring(record.observer_generation)
		.. ">"
		.. object_key(record.target_kind, record.target_id)
		.. ":"
		.. tostring(record.incarnation)
		.. ":"
		.. tostring(record.epoch)
end

local function registered_camera(observer)
	local registered = get_runtime().core:observer(object_key("camera", observer:id()))
	return registered and registered.unit == observer and registered or nil
end

function M:is_camera(observer)
	return registered_camera(observer) ~= nil
end

function M:has_active_target(observer, target)
	local registered = registered_camera(observer)
	if not registered then
		return false
	end
	local record = self.outgoing[record_key({
		observer_id = registered.id,
		observer_generation = registered.generation,
		target_kind = target.kind,
		target_id = target.id,
		incarnation = target.incarnation,
		epoch = target.epoch,
	})]
	return record ~= nil and record.active
end

function M:reset()
	self.incoming, self.outgoing, self.sent, self.owed = {}, {}, {}, {}
end

local function forget(self, matches)
	for key, pending in pairs(self.incoming) do
		if matches(pending.record) then
			self.incoming[key] = nil
		end
	end
	for key, record in pairs(self.outgoing) do
		if matches(record) then
			self.outgoing[key] = nil
			for _, sent in pairs(self.sent) do
				sent[key] = nil
			end
			for _, owed in pairs(self.owed) do
				owed[key] = nil
			end
		end
	end
end

function M:forget_target(kind, id)
	forget(self, function(record)
		return record.target_kind == kind and record.target_id == id
	end)
end

function M:forget_observer(id)
	forget(self, function(record)
		return record.observer_id == id
	end)
end

function M:forget_peer(peer_id)
	self.sent[peer_id], self.owed[peer_id] = nil, nil
end

local function deliver(self, runtime, peer_id, key)
	local partial = self.outgoing[key]
	local identity = runtime.core:prediction_peer_state(peer_id)
	if not partial or not identity then
		return false
	end
	local sent = self.sent[peer_id]
	if not sent or sent.session_id ~= identity.session_id or sent.membership_id ~= identity.membership_id then
		sent = { session_id = identity.session_id, membership_id = identity.membership_id }
	end
	if sent[key] ~= partial.seq then
		local record = { session_id = identity.session_id, membership_id = identity.membership_id }
		for field, value in pairs(partial) do
			record[field] = value
		end
		if not transport:send(peer_id, CHANNEL, record) then
			return false
		end
		sent[key] = partial.seq
	end
	self.sent[peer_id] = sent
	if self.owed[peer_id] then
		self.owed[peer_id][key] = nil
	end
	return true
end

function M:host_progress(suspect, observer, status)
	local runtime = get_runtime()
	if
		not runtime.core.is_host
		or not runtime:is_active()
		or not alive(suspect)
		or not alive(observer)
		or status ~= nil and status ~= false and type(status) ~= "number"
	then
		return nil
	end
	local target = runtime:target_for_unit(suspect)
	local registered = registered_camera(observer)
	if not target or target.unit ~= suspect or not registered then
		return nil
	end
	local _, epoch = runtime.core:get_source_owner(target.kind, target.id)
	if not epoch then
		return nil
	end
	local session = managers.network and managers.network:session()
	if not session then
		return nil
	end
	local partial = {
		observer_id = registered.id,
		observer_generation = registered.generation,
		target_kind = target.kind,
		target_id = target.id,
		incarnation = target.incarnation,
		epoch = epoch,
		active = status ~= false and status ~= nil,
	}
	local key = record_key(partial)
	local previous = self.outgoing[key]
	local seq = previous and previous.active == partial.active and previous.seq or (previous and previous.seq or 0) + 1
	partial.seq = seq
	self.outgoing[key] = partial

	local responsible = {}
	local now = runtime.network_time or 0
	for peer_id in pairs(session:peers()) do
		if
			runtime:is_peer_capable(peer_id)
			and features.allows_peer(peer_id, "detection")
			and runtime.core:prediction_peer_state(peer_id)
		then
			if deliver(self, runtime, peer_id, key) then
				responsible[peer_id] = true
			else
				local owed = self.owed[peer_id] or {}
				self.owed[peer_id] = owed
				owed[key] = owed[key] or now + M.RECOVERY
				responsible[peer_id] = now < owed[key] or nil
			end
		end
	end
	return responsible
end

local function prune(self, runtime, identity, key, pending)
	local record = pending.record
	if record.session_id ~= identity.session_id or record.membership_id ~= identity.membership_id then
		self.incoming[key] = nil
		return false
	end
	local observer_key = object_key("camera", record.observer_id)
	local target_key = object_key(record.target_kind, record.target_id)
	local observer = runtime.core:observer(observer_key)
	local target = runtime.core:target(target_key)
	local observer_history = runtime.core:observer_generation(observer_key)
	local target_history = runtime.core:incarnation(target_key)
	local _, epoch = runtime.core:get_source_owner(record.target_kind, record.target_id)
	if
		not observer and observer_history and observer_history >= record.observer_generation
		or not target and target_history and target_history >= record.incarnation
		or observer and observer.generation > record.observer_generation
		or target and target.incarnation > record.incarnation
		or target and epoch and epoch > record.epoch
	then
		self.incoming[key] = nil
		return false
	end
	return true, observer, target, epoch
end

local function process(self, runtime, identity, key, pending)
	local valid, observer, target, epoch = prune(self, runtime, identity, key, pending)
	if not valid then
		return
	end
	local record = pending.record
	if pending.applied == record.seq then
		return
	end
	local current = target and alive(target.unit) and runtime:target_for_unit(target.unit)
	if current and (current.kind ~= record.target_kind or current.id ~= record.target_id) then
		pending.applied = record.seq
	elseif
		observer
		and observer.generation == record.observer_generation
		and target
		and target.incarnation == record.incarnation
		and epoch == record.epoch
		and alive(observer.unit)
		and alive(target.unit)
	then
		if adapters.camera.target_hud_blocked(observer.unit, record.active) then
			pending.applied = record.seq
		elseif
			not runtime:prediction_for_unit(target.unit)
			and runtime.core:is_owned(target.kind, target.id, runtime.local_peer_id)
		then
			pending.applied = record.seq
		elseif current and current.unit == target.unit and not runtime:prediction_for_unit(target.unit) then
			adapters.camera.apply_target_hud(observer.unit, target.unit, record.active)
			pending.applied = record.seq
		end
	end
end

function M:receive(peer_id, record)
	record = Records.validate_camera_hud(record)
	if not record then
		return false
	end
	local runtime = get_runtime()
	if runtime.core.is_host or peer_id ~= runtime.host_peer_id or not runtime.current_session then
		return false
	end
	local key = record_key(record)
	local prior = self.incoming[key]
	if prior and prior.record.seq >= record.seq then
		return false
	end
	if not prior then
		local count = 0
		for _ in pairs(self.incoming) do
			count = count + 1
		end
		if count >= LIMIT then
			local identity = runtime.core:prediction_identity()
			if identity then
				for stale_key, pending in pairs(self.incoming) do
					prune(self, runtime, identity, stale_key, pending)
				end
			end
			count = 0
			for _ in pairs(self.incoming) do
				count = count + 1
			end
			if count >= LIMIT then
				return false
			end
		end
	end
	local pending = { record = record }
	self.incoming[key] = pending
	if runtime:is_active() and runtime.core:prediction_identity() then
		process(self, runtime, runtime.core:prediction_identity(), key, pending)
	end
	return true
end

function M:update(runtime)
	runtime = runtime or get_runtime()
	if runtime.core.is_host then
		for peer_id, owed in pairs(self.owed) do
			if not runtime:is_peer_capable(peer_id) or not features.allows_peer(peer_id, "detection") then
				self.owed[peer_id] = nil
			else
				for key in pairs(owed) do
					deliver(self, runtime, peer_id, key)
				end
			end
		end
		return
	end
	if not runtime:is_active() then
		return
	end
	local identity = runtime.core:prediction_identity()
	if not identity then
		return
	end
	for key, pending in pairs(self.incoming) do
		process(self, runtime, identity, key, pending)
	end
end

return M
