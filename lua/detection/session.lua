local Runtime, State, engine_alive, log_event, adapters, transport, camera_hud, features = ...
local object_key = State.object_key

local toggle_cleanup, session_changed = function() end, function() end

function Runtime.on_toggle_cleanup(fn)
	toggle_cleanup = fn
end

function Runtime.on_session_changed(fn)
	session_changed = fn
end

function Runtime:session()
	local session = managers and managers.network and managers.network:session()

	if session == self.ignored_session then
		return self.current_session or nil
	end

	self.ignored_session = nil

	return session
end

function Runtime:_reset_session_state(session, reset_detection)
	adapters.npc.clear_surrender_prediction()
	local changed_session = self.current_session ~= session
	if reset_detection or changed_session then
		features.reset()
	end
	self:_reset_predictions()
	transport:reset(session)
	camera_hud:reset()
	for _, record in pairs(self.core:owners()) do
		self:_on_cleanup(record, nil)
	end
	self:clear_local_views()
	if adapters.npc and adapters.npc.clear_session then
		adapters.npc.clear_session()
	end
	adapters.world_target.clear_session()
	if adapters.guard and adapters.guard.clear_host_observations then
		adapters.guard.clear_host_observations()
	end

	self.current_session = session
	self.mode = not session and "inactive" or self.core.is_host and "host_active" or "client_pending"
	self.capable_peers = {}
	self.preferred_owners = {}
	self.local_report_seq = {}
	self.hello_attempts = 0
	self.next_hello_t = 0
	self.observer_details = {}
	self.observer_unit_keys = {}
	self.pending_camera = {}
	self.pending_outbound = {}
	self.acked_snapshot = {}
	self.sent_base = {}
	self.sent_snapshots = {}
	self.remote_camera_suspicion = {}
	self.world_tombstones = {}
	self.last_snapshot_ready = nil
	self.seed_failed = {}
	self.dirty_state = nil
	self.network_time = 0
	self.next_flush_t = 0
	self.scope_stack = {}
	self.target_by_unit = {}

	self.npc_alert_events = setmetatable({}, { __mode = "k" })
	self.core:reset()
	if reset_detection or changed_session then
		session_changed(self.mode == "host_active")
	end

	if self.core.is_host and session then
		self.capable_peers[self.local_peer_id] = true
	end

	log_event("session_state", { "mode", self.mode, "peer", self.local_peer_id })
end

function Runtime:clear_local_views()
	if adapters.guard and adapters.guard.clear_session then
		adapters.guard.clear_session()
	end
	if adapters.player and adapters.player.clear_session then
		adapters.player.clear_session()
	end
	if adapters.camera and adapters.camera.clear_session then
		adapters.camera.clear_session(self.core:observers_of("camera"))
	end
end

function Runtime:reset_session(session)
	local managed_session = managers and managers.network and managers.network:session()
	self.ignored_session = managed_session ~= session and managed_session or nil
	local peer = session and session:local_peer()
	local peer_id = peer and peer:id() or self.host_peer_id

	self.local_peer_id = peer_id
	self.core:set_session_identity(peer_id, session ~= nil and Network and Network:is_server() or false)
	self:_reset_session_state(session, true)
	self.enabled = true
end

function Runtime:reject_snapshots_through(sequence)
	self.core:raise_snapshot_floor(sequence)
end

function Runtime:applied_snapshot_after(sequence)
	return self.core:snapshot_seq() > sequence
end

function Runtime:set_enabled(enabled)
	if type(enabled) ~= "boolean" or self.enabled == enabled then
		return false
	end
	if enabled and self.enabled == nil then
		self.enabled = true
		return false
	end
	local session = self:session()
	local targets, observers = {}, {}
	for key, target in pairs(self.core:targets()) do
		targets[#targets + 1] = { target, self.core:target_config(key), self.preferred_owners[key] }
	end
	for key, observer in pairs(self.core:observers()) do
		observers[#observers + 1] = { observer, self.observer_details[key] }
	end
	self:_reset_session_state(session)
	self.enabled = enabled
	toggle_cleanup(session)
	for _, saved in ipairs(targets) do
		local target, config, preferred = saved[1], saved[2], saved[3]
		if engine_alive(target.unit) then
			self:register_target(target.kind, target.id, target.unit, { config = config })
			if preferred then
				self.preferred_owners[object_key(target.kind, target.id)] = preferred
			end
		end
	end
	for _, saved in ipairs(observers) do
		local observer = saved[1]
		if engine_alive(observer.unit) then
			self:register_observer(observer.kind, observer.id, observer.unit, saved[2])
			if enabled and observer.kind == "guard" and adapters.npc and adapters.npc.bind then
				adapters.npc.bind(observer.unit)
			end
		end
	end
	if enabled then
		self:sync_players()
		if not self.core.is_host then
			self:send_hello()
		end
	end
	log_event("runtime_enabled", { "enabled", enabled })
	return true
end

function Runtime:refresh_session()
	local session = self:session()
	local peer = session and session:local_peer()
	local peer_id = peer and peer:id() or self.host_peer_id
	local role_matches = session == nil and self.core.is_host == false
		or session and type(session.is_host) == "function" and self.core.is_host == session:is_host()
	if self.current_session == session and self.local_peer_id == peer_id and role_matches then
		return peer_id
	end

	local previous_peer_id, was_host = self.local_peer_id, self.core.is_host
	local same_session = self.current_session == session
	self.local_peer_id = peer_id
	self.core:set_session_identity(peer_id, session ~= nil and Network and Network:is_server() or false)

	if self.current_session ~= session then
		self:_reset_session_state(session)
	elseif self.core.is_host and session then
		self.mode = "host_active"
		self.capable_peers[peer_id] = true
	elseif was_host and session then
		self.mode = "client_pending"
		self.capable_peers[previous_peer_id] = nil
	end
	if same_session and (was_host ~= self.core.is_host or previous_peer_id ~= peer_id) then
		session_changed(self.core.is_host)
	end

	return peer_id
end

function Runtime:_peer_eligible(peer_id)
	local session = self:session()
	local local_peer = session and session:local_peer()
	local peer = session and session:peer(peer_id)

	return local_peer and local_peer:id() == peer_id and (not local_peer.synched or local_peer:synched())
		or peer and (not peer.synched or peer:synched())
end

function Runtime:can_own(peer_id, kind)
	assert(features.is_kind(kind), "ClientsideStealth: can_own needs a target kind")
	return peer_id == self.host_peer_id or self.capable_peers[peer_id] == true and features.allows_peer(peer_id, kind)
end

function Runtime:delegates(peer_id, kind)
	if self.core.is_host then
		return peer_id ~= self.host_peer_id and self:can_own(peer_id, kind)
	end
	return peer_id == self.local_peer_id and features.allows(kind)
end

function Runtime:is_active()
	local state = managers and managers.groupai and managers.groupai:state()
	return self.enabled ~= false
		and (self.mode == "host_active" or self.mode == "client_active")
		and (not state or state:whisper_mode())
end

function Runtime:is_peer_capable(peer_id)
	return self.capable_peers[peer_id] == true and self:_peer_eligible(peer_id)
end

function Runtime:peer_lost(peer_id)
	if not self.core.is_host and peer_id == self.host_peer_id then
		self:reset_session(nil)

		return {}, true
	end

	local player = self.core:target(object_key("player", peer_id))
	features.peer_lost(peer_id)
	camera_hud:forget_peer(peer_id)
	self.capable_peers[peer_id] = nil
	self.pending_outbound[peer_id] = nil
	self.acked_snapshot[peer_id] = nil
	self.sent_base[peer_id] = nil
	self.sent_snapshots[peer_id] = nil
	self:_forget_peer_predictions(peer_id)
	self.core:abort_snapshot()

	for key, preferred in pairs(self.preferred_owners) do
		if preferred.peer_id == peer_id then
			self.preferred_owners[key] = nil
		end
	end
	local cancelled = self.core:cancel_peer_handoffs(peer_id)

	if player then
		self:unregister_target("player", peer_id)
	end

	local changed = self.core:peer_lost(peer_id)
	if player or #changed > 0 or #cancelled > 0 then
		self:mark_state_dirty()
	end

	return changed, player ~= nil or #changed > 0 or #cancelled > 0
end

return Runtime
