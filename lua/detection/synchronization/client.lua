local Runtime, engine_alive, log_event, adapters, transport = ...

function Runtime:_retry_target_configs()
	local applied = false
	for key, owner in pairs(self.core:queued_owners()) do
		local unit = self.prediction_bindings and self.prediction_bindings[key]
		if owner.kind == "npc" and not self.core:target(key) and engine_alive(unit) and unit:id() == owner.id then
			self:register_target(owner.kind, owner.id, unit, { incarnation = owner.incarnation })
		end
	end
	for key, config in pairs(self.core:queued_configs()) do
		local target = self.core:target(key)
		if target and target.incarnation == config.incarnation and engine_alive(target.unit) then
			applied = self.core:apply_target_config(config) == true or applied
		end
	end
	return applied
end

function Runtime:_retry_camera_state()
	for id in pairs(self.pending_camera) do
		if self.core:camera_state(id) then
			self:_on_camera_enabled(id)
		else
			self.pending_camera[id] = nil
		end
	end
	for key, owner in pairs(self.core:owners()) do
		if owner.owner_peer_id == self.local_peer_id and self.seed_failed[key] then
			self:_on_owner(owner)
		end
	end
end

function Runtime:_on_snapshot_commit(configs_retried)
	if not configs_retried then
		self:_retry_target_configs()
	end
	self:_retry_camera_state()
	adapters.bag.retry_pending_held()
	if not self.core.is_host and self:session() then
		if next(self.pending_camera) or self.core:has_queued_cameras() then
			log_event("snapshot_not_ready", { "peer", self.local_peer_id, "camera", "pending" })
			return
		end
		for _, owner in pairs(self.core:queued_owners()) do
			if owner.pending_owner_peer_id == self.local_peer_id then
				return
			end
		end
		for key, owner in pairs(self.core:owners()) do
			if owner.pending_owner_peer_id == self.local_peer_id then
				local target = self.core:target(key)
				local config = self.core:target_config(key)
				if
					not target
					or target.incarnation ~= owner.incarnation
					or self.core:queued_config(key)
					or config and config.incarnation ~= owner.incarnation
					or owner.kind ~= "player" and owner.kind ~= "vehicle" and not config
					or self.seed_failed[key]
				then
					log_event("snapshot_not_ready", { "peer", self.local_peer_id, "target", key })
					return
				end
			end
		end
		self.capable_peers[self.host_peer_id] = true
		self.mode = "client_active"
		log_event("client_active", {
			"peer",
			self.local_peer_id,
			"host",
			self.host_peer_id,
			"snapshot",
			self.core:snapshot_seq(),
		})
		if transport:available() then
			if transport:send(self.host_peer_id, transport.channel.ready, self.core:snapshot_seq()) then
				self.last_snapshot_ready = self.core:snapshot_seq()
			end
		end
	end
end

function Runtime:_on_snapshot_begin(snapshot_seq)
	if not self.core.is_host and self:session() then
		if self.mode ~= "client_active" then
			self.mode = "client_syncing"
		end
		log_event("snapshot_begin", { "peer", self.local_peer_id, "host", self.host_peer_id, "snapshot", snapshot_seq })
	end
end

function Runtime:send_hello()
	self:refresh_session()

	if
		self.enabled == false
		or self.core.is_host
		or self.mode ~= "client_pending"
		or not transport:available()
		or not self:session()
	then
		return false
	end

	if not transport:start(self.host_peer_id) then
		return false
	end
	local sent, reason = transport:send(self.host_peer_id, transport.channel.hello, Runtime.PROTOCOL_TOKEN)
	if not sent then
		return false, reason
	end
	log_event(
		"hello_sent",
		{ "peer", self.local_peer_id, "host", self.host_peer_id, "protocol", Runtime.PROTOCOL_TOKEN }
	)

	return true
end

function Runtime:request_resync()
	if
		not self:is_active()
		or self.core.is_host
		or not transport:available()
		or not self:session()
		or not self.capable_peers[self.host_peer_id]
	then
		return false
	end

	return transport:send(self.host_peer_id, transport.channel.resync, "")
end

return Runtime
