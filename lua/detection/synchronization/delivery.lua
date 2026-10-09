local Runtime, Records, State, engine_alive, HANDOFF_TIMEOUT, copy_record, log_event, adapters, transport, control_host, camera_hud =
	...
local reject = Records.reject
local valid_integer = Records.valid_integer
local valid_number = Records.valid_number
local HELLO_RETRY_INTERVAL = 2
local HELLO_RETRY_LIMIT = 15
local NETWORK_FLUSH_INTERVAL = 0.5
local SNAPSHOT_RETRY_INTERVAL = 1
local SENT_SNAPSHOT_LIMIT = 8
local object_key = State.object_key

function Runtime:_handoff_timeout(peer_id)
	local session = self:session()
	local peer = session and session.peer and session:peer(peer_id)
	local qos = peer and peer.qos and peer:qos()
	local ping = qos and qos.ping
	return valid_number(ping) and ping >= 0 and math.min(30, HANDOFF_TIMEOUT + 4 * ping / 1000) or HANDOFF_TIMEOUT
end

local function persistent_activation(self, outbound)
	local persistent, obsolete = false, false
	if outbound and outbound.phase == "activate" then
		for _, handoff in ipairs(outbound.handoffs) do
			persistent = persistent or self.core:is_handoff_persistent(handoff)
			local current = self.core:pending_handoff(object_key(handoff.kind, handoff.id))
			obsolete = obsolete or not current or current.handoff_id ~= handoff.handoff_id
		end
	end
	return persistent, obsolete
end

local function send_snapshot_records(peer, records)
	for _, record in ipairs(records) do
		local sent, reason = transport:send(peer, transport.channel.state, record)
		if not sent then
			return false, reason or "transport_send_failed"
		end
	end
	return true
end

function Runtime:mark_state_dirty()
	if self.core.is_host then
		self.dirty_state = true
		for _, pending in pairs(self.pending_outbound) do
			pending.needs_refresh = true
		end
	end
end

function Runtime:receive_hello(peer_id, body)
	self:refresh_session()

	if not self.core.is_host then
		return reject("not_host")
	end
	if body ~= Runtime.PROTOCOL_TOKEN then
		return reject("invalid_hello")
	end
	if peer_id == self.local_peer_id or not self:_peer_eligible(peer_id) then
		return reject("ineligible_peer")
	end
	if not control_host.on_hello(peer_id) then
		return reject("runtime_disabled")
	end

	self:sync_players()
	log_event("hello_accepted", { "peer", peer_id, "duplicate", self.capable_peers[peer_id] == true })
	self.acked_snapshot[peer_id], self.sent_base[peer_id] = nil, nil

	if self.capable_peers[peer_id] then
		self:send_snapshot(peer_id)

		return true
	end

	self.capable_peers[peer_id] = true
	local changed = false

	for _, preferred in pairs(self.preferred_owners) do
		if preferred.peer_id == peer_id and self.core:target(object_key(preferred.kind, preferred.id)) then
			local old_owner, old_epoch = self.core:get_owner(preferred.kind, preferred.id)
			local record = self.core:prepare_owner(
				preferred.kind,
				preferred.id,
				peer_id,
				self.network_time,
				self:_handoff_timeout(peer_id)
			)

			if record and (record.owner_peer_id ~= old_owner or record.epoch ~= old_epoch) then
				changed = true
			end
		end
	end

	if changed then
		self:send_snapshot()
	else
		self:send_snapshot(peer_id)
	end

	return true
end

function Runtime:update_network(wall_time)
	adapters.npc.update_surrender_prediction()
	if self.enabled == false then
		return false
	end
	if not valid_number(wall_time) then
		return false
	end
	self.network_time = wall_time
	self:update_predictions(wall_time)
	camera_hud:update(self)
	self:prune_remote_observations()
	if self.core.is_host then
		local changed = false
		for _, pending in ipairs(self.core:expire_handoffs(wall_time)) do
			if pending.kind == "npc" then
				self:_root_handoff_expired(pending)
			end
			if pending.kind == "bag" then
				local outbound = self.pending_outbound[pending.owner_peer_id]
				for _, handoff in ipairs(outbound and outbound.handoffs or {}) do
					if handoff.kind == pending.kind and handoff.id == pending.id and handoff.epoch == pending.epoch then
						if not persistent_activation(self, outbound) then
							self.pending_outbound[pending.owner_peer_id] = nil
						end
						break
					end
				end
			end
			log_event(
				"handoff_timeout",
				{ "target", object_key(pending.kind, pending.id), "peer", pending.owner_peer_id }
			)
			changed = true
		end
		if changed then
			self:mark_state_dirty()
		end
		local state = managers and managers.groupai and managers.groupai:state()
		if state and not state:whisper_mode() then
			return changed
		end
		for peer_id, pending in pairs(self.pending_outbound) do
			if wall_time >= pending.next_retry_t then
				local persistent, obsolete = persistent_activation(self, pending)
				if persistent and obsolete then
					self:send_snapshot(peer_id, peer_id)
				elseif not persistent and wall_time >= pending.deadline then
					self.pending_outbound[peer_id] = nil
					local dirty = pending.send_failed or pending.needs_refresh
					if pending.phase == "activate" then
						for _, handoff in ipairs(pending.handoffs) do
							self.core:cancel_prepared_owner(handoff)
						end
						self:mark_state_dirty()
					end
					if dirty then
						self.dirty_state = true
					end
				else
					pending.attempts = pending.attempts + 1
					pending.next_retry_t = persistent and wall_time + SNAPSHOT_RETRY_INTERVAL
						or math.min(wall_time + SNAPSHOT_RETRY_INTERVAL, pending.deadline)
					if pending.send_failed then
						pending.send_failed = not (
							self:_publish_prediction_identity(peer_id)
							and send_snapshot_records(peer_id, pending.records)
						)
					else
						local sent, reason = transport:send(peer_id, transport.channel.state, pending.records[1])
						if not sent then
							log_event("snapshot_probe_failed", { "peer", peer_id, "reason", reason })
						end
					end
				end
			end
		end
		if self.dirty_state and wall_time >= self.next_flush_t then
			self.dirty_state = nil
			self.next_flush_t = wall_time + NETWORK_FLUSH_INTERVAL
			local sent = self:send_snapshot()
			self.dirty_state = not sent and true or nil
			return sent
		end
		return changed
	end
	if wall_time >= self.next_flush_t then
		self.next_flush_t = wall_time + NETWORK_FLUSH_INTERVAL
		self:_retry_target_configs()
		if
			self.core:snapshot_seq() >= 0
			and not self.core:has_pending_snapshot()
			and self.last_snapshot_ready ~= self.core:snapshot_seq()
		then
			self:_on_snapshot_commit(true)
		end
	end
	if self.mode ~= "client_pending" or self.hello_attempts >= HELLO_RETRY_LIMIT or wall_time < self.next_hello_t then
		return false
	end

	self.next_hello_t = wall_time + HELLO_RETRY_INTERVAL
	local sent, reason = self:send_hello()
	if sent then
		self.hello_attempts = self.hello_attempts + 1
	end
	return sent, reason
end

function Runtime:invalidate_snapshot_for_peer(peer_id)
	self.pending_outbound[peer_id] = nil
	self:mark_state_dirty()
end

function Runtime:refresh_snapshot_for_peer(peer_id)
	local persistent, obsolete = persistent_activation(self, self.pending_outbound[peer_id])
	if not persistent then
		return self:invalidate_snapshot_for_peer(peer_id)
	end
	self:mark_state_dirty()
	if obsolete then
		self:send_snapshot(peer_id, peer_id)
	end
end

function Runtime:receive_resync(peer_id)
	self.acked_snapshot[peer_id], self.sent_base[peer_id] = nil, nil
	self:invalidate_snapshot_for_peer(peer_id)
	return self:send_snapshot(peer_id)
end

function Runtime:receive_ready_record(peer_id, snapshot_seq)
	self:refresh_session()

	if not self.core.is_host then
		return reject("not_host")
	end
	if not self:is_peer_capable(peer_id) then
		return reject("unconfirmed_peer")
	end
	local pending = self.pending_outbound[peer_id]

	if not valid_integer(snapshot_seq) then
		return reject("invalid_ready")
	end
	local sent = self.sent_snapshots[peer_id]
	local acked = self.acked_snapshot[peer_id]
	if sent and sent[snapshot_seq] and (not acked or acked.seq < snapshot_seq) then
		self.acked_snapshot[peer_id] = { seq = snapshot_seq, set = sent[snapshot_seq] }
	end
	if not pending or pending.seq ~= snapshot_seq then
		return reject("stale_snapshot")
	end
	if self.network_time >= pending.deadline and not persistent_activation(self, pending) then
		return reject("stale_snapshot")
	end

	self.pending_outbound[peer_id] = nil
	if pending.needs_refresh then
		self.dirty_state = true
	end
	if pending.phase == "prepare" and #pending.handoffs > 0 then
		return self:send_snapshot(peer_id, peer_id)
	end
	local committed, refresh = false, false
	if pending.phase == "activate" then
		for _, handoff in ipairs(pending.handoffs) do
			if self.core:handoff_needs_refresh(handoff) then
				refresh = true
			else
				committed = self.core:commit_prepared_owner(handoff) and true or committed
			end
		end
	end
	log_event("snapshot_ready", { "peer", peer_id, "snapshot", snapshot_seq, "committed", committed })
	if committed then
		self:mark_state_dirty()
	end
	if refresh then
		return self:send_snapshot(peer_id, peer_id)
	end
	if self:_retry_root_handoffs(peer_id) then
		return self:send_snapshot(peer_id, peer_id)
	end

	return true
end

function Runtime:send_snapshot(peer_id, activate_peer_id, requested_handoff)
	if not self.core.is_host or not transport:available() then
		return false
	end
	local outbound = peer_id and self.pending_outbound[peer_id]
	if
		requested_handoff
		and requested_handoff.persistent
		and activate_peer_id == peer_id
		and outbound
		and outbound.phase == "activate"
	then
		for _, captured in ipairs(outbound.handoffs) do
			if
				captured.persistent
				and captured.handoff_id == requested_handoff.handoff_id
				and self.core:is_handoff_persistent(captured)
			then
				return true
			end
		end
	end
	local groupai_state = managers and managers.groupai and managers.groupai:state()
	if groupai_state and not groupai_state:whisper_mode() then
		return false
	end
	local recipients = {}

	if peer_id then
		if
			peer_id ~= self.local_peer_id
			and self:is_peer_capable(peer_id)
			and (activate_peer_id or not self.pending_outbound[peer_id])
		then
			recipients[1] = peer_id
		end
	else
		for capable_peer_id in pairs(self.capable_peers) do
			if
				capable_peer_id ~= self.local_peer_id
				and self:is_peer_capable(capable_peer_id)
				and not self.pending_outbound[capable_peer_id]
			then
				recipients[#recipients + 1] = capable_peer_id
			end
		end
		table.sort(recipients)
	end

	if #recipients == 0 then
		return false
	end

	local adapter = adapters.camera
	if adapter and adapter.snapshot then
		for _, observer in pairs(self.core:observers()) do
			if observer.kind == "camera" and engine_alive(observer.unit) then
				self:update_camera_state(observer.id, adapter.snapshot(observer.unit))
			end
		end
	end

	local first_error
	local cool_guards = {}
	local function include_observation(observation)
		if observation.observer_kind ~= "guard" then
			return true
		end
		local key = observation.observer_key
		if cool_guards[key] == nil then
			local observer = self.core:observer(key)
			cool_guards[key] = observer ~= nil
				and engine_alive(observer.unit)
				and observer.unit:movement():cool() == true
		end
		return cool_guards[key] == true
	end
	for _, recipient in ipairs(recipients) do
		self.snapshot_seq = self.snapshot_seq + 1
		local records, error_code = self.core:snapshot_records(
			self.snapshot_seq,
			activate_peer_id == recipient and recipient or nil,
			include_observation
		)
		if not records then
			return false, error_code
		end

		local full_set
		records, full_set =
			self.core:snapshot_delta(records, self.sent_base[recipient] or self.acked_snapshot[recipient])
		local recent = self.sent_snapshots[recipient] or {}
		self.sent_snapshots[recipient] = recent
		recent[self.snapshot_seq] = full_set
		local oldest, count = nil, 0
		for seq in pairs(recent) do
			oldest, count = math.min(oldest or seq, seq), count + 1
		end
		if count > SENT_SNAPSHOT_LIMIT then
			recent[oldest] = nil
		end
		local handoffs, deadline = {}, nil
		for _, handoff in pairs(self.core:pending_handoffs()) do
			if handoff.owner_peer_id == recipient then
				local state = copy_record(handoff)
				state.observation_revision = self.core:observation_revision(object_key(handoff.kind, handoff.id)) or 0
				handoffs[#handoffs + 1] = state
				if not handoff.persistent and handoff.deadline then
					deadline = math.min(deadline or handoff.deadline, handoff.deadline)
				end
			end
		end
		deadline = deadline or self.network_time + self:_handoff_timeout(recipient)
		local pending = {
			seq = self.snapshot_seq,
			records = records,
			handoffs = handoffs,
			phase = activate_peer_id == recipient and "activate" or "prepare",
			attempts = 1,
			deadline = deadline,
			next_retry_t = math.min(self.network_time + SNAPSHOT_RETRY_INTERVAL, deadline),
		}
		self.pending_outbound[recipient] = pending
		local sent, reason = self:_publish_prediction_identity(recipient)
		if sent then
			sent, reason = send_snapshot_records(recipient, records)
		end
		pending.send_failed = not sent
		self.sent_base[recipient] = sent and { seq = self.snapshot_seq, set = full_set } or nil
		if not sent and not first_error then
			first_error = reason
		end
	end

	return first_error == nil, first_error
end

return Runtime
