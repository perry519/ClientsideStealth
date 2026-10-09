local Runtime, Records, State, alive, adapters = ...
local key = State.object_key
local proof_key = Records.prediction_proof_key

function Runtime:_reset_alert_roots()
	self.detection_holds = {}
	self.alert_roots = {}
	self.native_alerts = {}
end

function Runtime:_prune_alert_roots()
	for unit_key, hold in pairs(self.detection_holds) do
		if not self:is_detection_held(hold.unit) then
			self.detection_holds[unit_key] = nil
		end
	end
	for unit_key, root in pairs(self.alert_roots) do
		if not alive(root.unit) then
			self.alert_roots[unit_key] = nil
		end
	end
end

function Runtime:has_detection_holds()
	return next(self.detection_holds) ~= nil
end

function Runtime:_release_detection_hold(unit)
	if alive(unit) then
		self.detection_holds[unit:key()] = nil
	end
end

function Runtime:_forget_native_alert(target)
	local native = self.native_alerts[target.unit:key()]
	if native and native.unit == target.unit and native.incarnation == target.incarnation then
		self.native_alerts[target.unit:key()] = nil
	end
end

function Runtime:_native_owner(proof)
	local source = proof.source and self.core:target(key(proof.source.kind, proof.source.id))
	if
		proof.peer_id ~= self.host_peer_id
		or not source
		or source.unit ~= proof.source_unit
		or source.incarnation ~= proof.source.incarnation
	then
		return proof.peer_id
	end
	local owner, epoch = self.core:get_source_owner(source.kind, source.id)
	if owner == self.host_peer_id then
		return self:alert_root(source.unit) or owner
	end

	local peer = self.core:prediction_peer_state(owner)
	for _, event in pairs(peer and peer.decisions or {}) do
		local decision = event.status == "accepted" and event.decision
		if
			decision
			and decision.kind == source.kind
			and decision.id == source.id
			and decision.incarnation == source.incarnation
			and decision.epoch == epoch
		then
			return owner
		end
	end
	return proof.peer_id
end

function Runtime:native_alert_for(target)
	local entry = target and self.native_alerts[target.unit:key()]
	if not entry or entry.unit ~= target.unit or entry.incarnation ~= target.incarnation then
		return nil
	end
	return entry.proof, not entry.proof and entry.source_unit or nil
end

function Runtime:defer_native_alert(unit, source_unit, cause, observer_kind, observer_id)
	local target = self:target_for_unit(unit)
	if not self.core.is_host or not target or target.kind ~= "npc" or self:native_alert_for(target) then
		return
	end
	local entry = self.native_alerts[unit:key()]
	if entry and entry.unit == unit and entry.incarnation == target.incarnation then
		return
	end
	self.native_alerts[unit:key()] = {
		unit = unit,
		incarnation = target.incarnation,
		source_unit = source_unit,
		cause = cause,
		observer_kind = observer_kind,
		observer_id = observer_id,
	}
end

function Runtime:resolve_native_alerts(source_unit)
	local confirm = adapters.npc and adapters.npc.confirm
	if not self.core.is_host or not confirm then
		return
	end
	for _, entry in pairs(self.native_alerts) do
		if entry.source_unit == source_unit and not entry.proof then
			local target = self:target_for_unit(entry.unit)
			if target and target.kind == "npc" and target.incarnation == entry.incarnation then
				confirm(entry.unit, source_unit, entry.cause, entry.observer_kind, entry.observer_id)
			end
		end
	end
end

function Runtime:_inherit_alert_root(source_target, peer_id, visited)
	for _, child in pairs(self.core:targets()) do
		local proof = child.kind == "npc" and self:native_alert_for(child)
		local source = proof and proof.source
		if
			proof
			and proof.peer_id == self.host_peer_id
			and source
			and source.kind == source_target.kind
			and source.id == source_target.id
			and source.incarnation == source_target.incarnation
			and proof.source_unit == source_target.unit
		then
			self:_attach_alert_root(child, peer_id, visited)
		end
	end
end

function Runtime:_attach_alert_root(target, peer_id, visited)
	if not target or target.kind ~= "npc" or not alive(target.unit) or not self.core:can_own(peer_id, "npc") then
		return
	end
	visited = visited or {}
	local target_key = key(target.kind, target.id)
	if visited[target_key] then
		return
	end
	visited[target_key] = true
	local unit_key = target.unit:key()
	local current = self.alert_roots[unit_key]
	if current and current.unit == target.unit and current.incarnation == target.incarnation then
		if current.peer_id ~= peer_id then
			return
		end
	else
		current = {
			unit = target.unit,
			kind = target.kind,
			id = target.id,
			incarnation = target.incarnation,
			config_revision = self.core:target_config_revision(target_key) or 0,
			peer_id = peer_id,
		}
		self.alert_roots[unit_key] = current
	end
	if self.core:get_owner(target.kind, target.id) ~= peer_id then
		self:assign_owner(target.kind, target.id, peer_id)
	end
	local handoff = self.core:pending_handoff(target_key)
	if handoff and handoff.owner_peer_id == peer_id then
		current.handoff_id = handoff.handoff_id
		if not self.core:detection_advanced(target_key, target.incarnation) then
			self.detection_holds[unit_key] = { unit = target.unit, key = target_key, peer_id = peer_id }
			local cleanup = adapters.guard and adapters.guard.cleanup_observer
			for _, observer in ipairs(cleanup and self.core:observers_of("guard") or {}) do
				if alive(observer.unit) then
					cleanup(observer.unit, target.unit)
				end
			end
		end
	end
	self:_inherit_alert_root(target, peer_id, visited)
end

function Runtime:_root_handoff_expired(handoff)
	local target_key = key(handoff.kind, handoff.id)
	local target = self.core:target(target_key)
	local root = target and self.alert_roots[target.unit:key()]
	if
		root
		and root.unit == target.unit
		and root.incarnation == handoff.incarnation
		and root.handoff_id == handoff.handoff_id
		and root.peer_id == handoff.owner_peer_id
		and root.config_revision == (self.core:target_config_revision(target_key) or 0)
		and not root.retry_used
	then
		root.retryable = true
	end
end

function Runtime:_retry_root_handoffs(peer_id)
	local retry = false
	for _, root in pairs(self.alert_roots) do
		local target_key = root.kind and root.id and key(root.kind, root.id)
		local target = self.core:target(target_key)
		local preferred = self.preferred_owners[target_key]
		if
			root.retryable
			and root.peer_id == peer_id
			and target
			and target.unit == root.unit
			and target.incarnation == root.incarnation
			and preferred
			and preferred.peer_id == peer_id
			and root.config_revision == (self.core:target_config_revision(target_key) or 0)
			and self.core:get_owner(root.kind, root.id) == self.host_peer_id
			and not self.core:pending_handoff(target_key)
			and self.core:can_own(peer_id, "npc")
		then
			root.retryable, root.retry_used = nil, true
			local handoff = self:assign_owner(root.kind, root.id, peer_id)
			if handoff and handoff.pending then
				root.handoff_id = handoff.handoff_id
				retry = true
			end
		end
	end
	return retry
end

function Runtime:is_detection_held(unit)
	local hold = alive(unit) and self.detection_holds[unit:key()]
	return hold
			and hold.unit == unit
			and self.core:can_own(hold.peer_id, "npc")
			and (self.core:pending_handoff(hold.key) or {}).owner_peer_id == hold.peer_id
		or false
end

function Runtime:alert_root(unit)
	local root = alive(unit) and self.alert_roots[unit:key()]
	local target = root and root.kind and root.id and self.core:target(key(root.kind, root.id))
	return root
			and root.unit == unit
			and target
			and target.unit == unit
			and target.incarnation == root.incarnation
			and self.core:can_own(root.peer_id, "npc")
			and root.peer_id
		or nil
end

function Runtime:_confirm_native_prediction(spec)
	local unit = spec.canonical_unit or spec.unit
	local source = self:_prediction_source(spec)
	local owner = spec.owner_peer_id or source and self.core:get_source_owner(source.kind, source.id)
	if owner == self.host_peer_id and source then
		owner = self:alert_root(source.unit) or owner
	end
	if not alive(unit) or not spec.cause or not source and not owner then
		return nil, "native_host_owned"
	end
	local target = self.target_by_unit[unit:key()]
	if not target or target.kind ~= spec.kind then
		return nil, "native_target_pending"
	end
	if target.kind == "npc" then
		local confirmed, pending_source = self:native_alert_for(target)
		if confirmed or pending_source and pending_source ~= (spec.source_unit or source and source.unit) then
			return target
		end
	end
	local record = {
		cause = spec.cause,
		subject_kind = spec.kind,
		subject_id = spec.subject_id or spec.id or unit:id(),
		subject_generation = spec.subject_generation or self:_prediction_subject(unit, spec.kind, spec.id or unit:id()),
		native_token = spec.native_key,
	}
	local count = 0
	for _ in pairs(self.prediction_proofs) do
		count = count + 1
	end
	if count >= self.core.PREDICTION_LIMIT.events * 4 then
		return nil, "native_proof_capacity"
	end
	local token = proof_key(record)
	local previous = self.prediction_proofs[token]
	if previous and previous.unit == unit then
		return target
	end
	local source_record
	if source then
		local _, epoch, current = self.core:get_source_owner(source.kind, source.id)
		if current then
			source_record = { kind = source.kind, id = source.id, incarnation = current.incarnation, epoch = epoch }
		end
	end
	local config = self.core:target_config(key(target.kind, target.id))
	local proof = {
		peer_id = owner,
		source = source_record,
		kind = target.kind,
		id = target.id,
		unit = unit,
		incarnation = target.incarnation,
		config_signature = Records.prediction_config_signature(config),
		config_revision = config and config.config_revision or 0,
		source_unit = spec.source_unit or source and source.unit,
		deadline = self.network_time + 10,
	}
	self.prediction_proofs[token] = proof
	if target.kind == "npc" then
		self.native_alerts[unit:key()] = { unit = unit, incarnation = target.incarnation, proof = proof }
	end
	local root = target.kind == "npc"
		and owner
		and owner ~= self.host_peer_id
		and self.core:can_own(owner, "npc")
		and owner
	if root then
		self:_attach_alert_root(target, root)
	end
	for peer_id, peer in pairs(self.core:prediction_peers()) do
		for _, event in pairs(peer.events) do
			if proof_key(event.record) == token then
				self:_try_prediction(peer_id, event)
			end
		end
	end
	return target
end

function Runtime:forget_prediction_proofs(kind, id, unit)
	local removed = 0
	for token, proof in pairs(self.prediction_proofs) do
		if proof.kind == kind and proof.id == id and proof.unit == unit then
			self.prediction_proofs[token] = nil
			removed = removed + 1
		end
	end
	return removed
end

return Runtime
