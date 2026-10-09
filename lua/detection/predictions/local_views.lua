local Runtime, Records, State, alive, copy, adapters, transport, control, peers = ...
local key = State.object_key
local CHANNEL = transport.channel.prediction
local RETRY_INTERVAL = 1
local MAX_RETRY_INTERVAL = 4
local function schedule_retry(entry, now)
	entry.retry_interval = math.min((entry.retry_interval or RETRY_INTERVAL / 2) * 2, MAX_RETRY_INTERVAL)
	entry.next_retry = now + entry.retry_interval
end
local function sent_reliably(peer_id, sent)
	return sent and transport:mode(peer_id) == "rpc" or false
end
Runtime._schedule_prediction_retry, Runtime._sent_reliably = schedule_retry, sent_reliably

local proof_key = Records.prediction_proof_key

local function drop_outgoing(self, target, seq)
	if target.outgoing[seq] then
		target.outgoing[seq] = nil
		self.prediction_outgoing_count = self.prediction_outgoing_count - 1
	end
end

local function drop_all_outgoing(self, target)
	for seq in pairs(target.outgoing) do
		drop_outgoing(self, target, seq)
	end
end

local function identity_record(self, op, event_id)
	local identity = self.core:prediction_identity()
	if not identity then
		return nil
	end
	return { op = op, session_id = identity.session_id, membership_id = identity.membership_id, event_id = event_id }
end
Runtime._prediction_record, Runtime._drop_prediction_outgoing = identity_record, drop_all_outgoing

function Runtime:_reset_predictions()
	for _, target in pairs(self.predicted_targets or {}) do
		self:_clear_prediction_view(target, "session_reset")
	end
	self.predicted_targets, self.predicted_units, self.predicted_keys = {}, {}, {}
	self.prediction_proofs, self.prediction_retries, self.prediction_unsettled = {}, {}, {}
	self.prediction_outgoing_count = 0
	self.prediction_bindings = {}
	self.npc_alert_marks = {}
	self:_reset_alert_roots()
	self.prediction_next_event = 0
	self.prediction_stats = { claims = 0, decisions = 0 }
end

function Runtime:_publish_prediction_identity(peer_id)
	local state = self.core:prediction_peer_state(peer_id)
	if not state then
		local membership = peers.join(peer_id)
		state = membership and self.core:register_prediction_peer(peer_id, peers.session_id(), membership)
	end
	if not state then
		return false
	end
	return transport:send(peer_id, CHANNEL, {
		op = "identity",
		session_id = state.session_id,
		membership_id = state.membership_id,
	})
end

function Runtime:prediction_source_authorized(peer_id, claim)
	local proof = self.prediction_proofs[proof_key(claim)]
	local source = proof and proof.source
	return self.core.is_host
			and source
			and proof.peer_id == peer_id
			and self.network_time < proof.deadline
			and source.kind == claim.source_kind
			and source.id == claim.source_id
			and source.incarnation == claim.source_incarnation
			and source.epoch == claim.source_epoch
		or false
end

function Runtime:prediction_for_unit(unit)
	if not next(self.predicted_units) then
		return nil
	end
	local target = alive(unit) and self.predicted_units[unit:key()]
	return target and target.unit == unit and target or nil
end

function Runtime:owns_detection(kind, id, peer_id)
	local target = self.predicted_keys[key(kind, id)]
	if target and peer_id == self.local_peer_id and not self.core.is_host then
		return alive(target.unit) and self:is_active()
	end
	return self.core:is_owned(kind, id, peer_id)
end

function Runtime:_prediction_subject(unit, kind, id)
	local observer = id and self.core:observer(key("guard", id))
	local target = alive(unit) and self.target_by_unit[unit:key()]
	return observer and observer.unit == unit and observer.generation
		or target and target.kind == kind and target.incarnation
		or 0
end

function Runtime:observer_identity(unit)
	if not alive(unit) then
		return nil
	end
	local observer = unit.id and self.core:observer(key("guard", unit:id()))
	return observer and observer.unit == unit and observer or nil
end

function Runtime:bind_predicted_unit(kind, id, unit)
	self.prediction_bindings[key(kind, id)] = unit
	for _, target in pairs(self.predicted_targets) do
		local decision = target.decision
		if decision and decision.kind == kind and decision.id == id then
			self:_promote_prediction(target, decision)
		end
	end
end

function Runtime:_prediction_source(spec)
	return spec.source
		or self:target_for_unit(spec.source_unit)
		or spec.owner_peer_id and self.core:target(key("player", spec.owner_peer_id))
end

function Runtime:predict_target(spec)
	if self.core.is_host or not self:is_active() or not alive(spec.unit) then
		return nil, "inactive_prediction"
	end
	if not control.allows_new_work(spec.kind) then
		if spec.kind == "npc" and control.allows_new_work(spec.mark_feature or "intimidation") then
			return self:_mark_npc_alert(spec)
		end
		return nil, "category_disabled"
	end
	local previous = self:prediction_for_unit(spec.unit)
	if previous and previous.cause == spec.cause then
		return previous
	end
	local count = 0
	for _ in pairs(self.predicted_targets) do
		count = count + 1
	end
	for _ in pairs(self.prediction_retries) do
		count = count + 1
	end
	if count >= self.core.PREDICTION_LIMIT.events then
		return nil, "prediction_capacity"
	end
	local source = self:_prediction_source(spec)
	if not source then
		return nil, "missing_prediction_source"
	end
	local claim = identity_record(self, "claim", self.prediction_next_event + 1)
	if not claim then
		return nil, "prediction_identity_pending"
	end
	claim.cause, claim.subject_kind = spec.cause, spec.kind
	claim.subject_id = spec.subject_id or spec.id or spec.unit.id and math.max(spec.unit:id(), 0) or 0
	claim.subject_generation = spec.subject_generation
		or self:_prediction_subject(spec.unit, spec.kind, claim.subject_id)
	claim.native_token = spec.native_key
	claim.config_signature = Records.prediction_config_signature(spec.config)
	if source.prediction then
		claim.parent_id = source.event_id
	else
		local owner, epoch, record = self.core:get_source_owner(source.kind, source.id)

		if owner ~= self.local_peer_id or not record or not control.allows_new_work(source.kind) then
			return nil, "unauthorized_source"
		end
		claim.source_kind, claim.source_id = source.kind, source.id
		claim.source_incarnation, claim.source_epoch = record.incarnation, epoch
	end
	local subject_pending = claim.subject_generation == 0 and not claim.native_token
	if subject_pending and spec.kind ~= "npc" then
		return nil, "subject_identity_pending"
	end
	local attention = spec.attention or adapters.world_target.prediction_attention(spec.unit, spec.config)
	if not attention then
		return nil, "unsupported_attention"
	end
	local record, reason = Records.validate_prediction(claim)
	if not record then
		return nil, reason
	end
	local event
	event, reason = self.core:begin_prediction(self.local_peer_id, record, self.network_time)
	if not event then
		return nil, reason
	end
	if previous then
		self:cancel_prediction_for_unit(spec.unit, "replaced")
	end
	self.prediction_next_event = claim.event_id
	local target = {
		kind = spec.kind,
		id = 1000000000 - claim.event_id,
		unit = spec.unit,
		prediction = true,
		event_id = claim.event_id,
		cause = spec.cause,
		config = spec.config,
		attention = attention,
		claim = claim,
		subject_pending = subject_pending,
		observations = {},
		outgoing = {},
		seq = 0,
		created = self.network_time,
		config_revision = 0,
		next_retry = self.network_time + RETRY_INTERVAL,
	}
	self.predicted_targets[target.event_id] = target
	self.predicted_units[spec.unit:key()] = target
	self.predicted_keys[key(target.kind, target.id)] = target
	self.prediction_stats.claims = self.prediction_stats.claims + 1
	if not subject_pending then
		target.claim_sent_rpc = sent_reliably(self.host_peer_id, transport:send(self.host_peer_id, CHANNEL, claim))
	end
	return target
end

function Runtime:clear_local_detection(unit)
	if self.core.is_host then
		return false
	end
	local target = self:prediction_for_unit(unit)
	if target then
		drop_all_outgoing(self, target)
		target.observations, target.feedback = {}, {}
	end
	if adapters.guard and adapters.guard.cleanup_target then
		adapters.guard.cleanup_target(unit)
	end
	if not alive(unit) then
		return true
	end
	for _, observer in pairs(self.core:observers()) do
		if observer.kind == "camera" and alive(observer.unit) then
			local camera = observer.unit:base()
			local entry = camera._detected_attention_objects and camera._detected_attention_objects[unit:key()]
			if entry then
				camera:_destroy_detected_attention_object_data(entry)
			end
		end
	end
	return true
end

function Runtime:_clear_prediction_view(target, reason)
	drop_all_outgoing(self, target)
	self.predicted_targets[target.event_id] = nil
	self.predicted_keys[key(target.kind, target.id)] = nil
	if self.predicted_units[target.unit:key()] == target then
		self.predicted_units[target.unit:key()] = nil
	end
	local adapter = adapters.npc
	if adapter and adapter.cancel_prediction then
		adapter.cancel_prediction(target.unit, reason)
	end
	self:clear_local_detection(target.unit)
end

function Runtime:cancel_predictions(reason, kinds)
	for _, target in pairs(self.predicted_targets) do
		if not kinds or kinds[target.kind] or kinds[target.claim.source_kind] then
			self:cancel_prediction_for_unit(target.unit, reason)
		end
	end
	if not kinds or kinds.npc then
		for _, mark in pairs(self.npc_alert_marks) do
			self:cancel_prediction_for_unit(mark.unit, reason)
		end
	end
end

function Runtime:cancel_prediction_for_unit(unit, reason)
	self:_cancel_npc_alert(unit, reason)
	local target = self:prediction_for_unit(unit)
	if not target then
		return false
	end
	local current = self.core:prediction(self.local_peer_id, target.event_id)
	local cancelled = self.core:reject_prediction(self.local_peer_id, target.event_id, reason or "cancelled")
	if not cancelled and current then
		cancelled = { current }
	end
	for _, event in ipairs(cancelled or {}) do
		local view = self.predicted_targets[event.record.event_id]
		if view then
			local record = identity_record(self, "cancel", view.event_id)
			record.reason = reason or "cancelled"
			local sent = transport:send(self.host_peer_id, CHANNEL, record)
			self.prediction_retries[view.event_id] = {
				record = record,
				deadline = self.network_time + 10,
				next_retry = self.network_time + 1,
				sent_rpc = sent_reliably(self.host_peer_id, sent),
			}
			self:_clear_prediction_view(view, reason)
		end
	end
	return true
end

function Runtime:retire_prediction_for_unit(unit, reason)
	if self.core.is_host then
		return false
	end
	local target = self:prediction_for_unit(unit)
	if not target then
		return false
	end

	self:_clear_prediction_view(target, reason)
	return true
end

function Runtime:send_prediction_report(target, observer_kind, observer_id, transition, value)
	if self:is_detection_suppressed(target.unit) then
		return nil, "held_target"
	end
	local deferred = adapters.npc.surrender_pending(target.unit)
	local observer = self.core:observer(key(observer_kind, observer_id))
	if not observer or not observer.generation or observer.generation == 0 then
		return nil, "observer_identity_pending"
	end
	local previous = target.observations[key(observer_kind, observer_id)]
	if not deferred and previous and previous.transition == transition and previous.value == value then
		return true, target.subject_pending and "queued" or nil
	end
	if target.seq >= self.core.PREDICTION_LIMIT.observations then
		self:cancel_prediction_for_unit(target.unit, "observation_capacity")
		return nil, "prediction_observation_capacity"
	end
	if self.prediction_outgoing_count >= self.core.PREDICTION_LIMIT.observations then
		return nil, "prediction_observation_capacity"
	end
	target.seq = target.seq + 1
	local record = identity_record(self, "observe", target.event_id)
	record.seq, record.observer_kind, record.observer_id = target.seq, observer_kind, observer_id
	record.observer_generation, record.config_revision = observer.generation, target.config_revision
	record.config_signature = target.claim.config_signature
	record.transition, record.value = transition, value
	local accepted, reason = Records.validate_prediction(record)
	if not accepted then
		return nil, reason
	end
	if not deferred then
		target.observations[key(observer_kind, observer_id)] = accepted
	end
	target.feedback = target.feedback or {}
	local feedback = target.feedback[key(observer_kind, observer_id)] or {}
	feedback.transition, feedback.local_detection = transition, true
	feedback.seq = record.seq
	feedback.value, feedback.observer_generation = value, observer.generation
	feedback.observer_unit = observer.unit
	feedback.cleared = transition == "clear" or transition == "lost"
	if feedback.cleared then
		feedback.notice_progress, feedback.suspicion_progress = nil, nil
		feedback.identified, feedback.alarmed = nil, nil
	elseif transition == "notice" then
		feedback[observer_kind == "guard" and "notice_progress" or "suspicion_progress"] = value
	elseif transition == "suspicion" then
		feedback.suspicion_progress = value
	elseif transition == "identified" then
		feedback.notice_progress, feedback.identified = 1, true
	elseif transition == "alarm" then
		feedback.suspicion_progress, feedback.alarmed = 1, true
	end
	target.feedback[key(observer_kind, observer_id)] = feedback
	if deferred then
		self:defer_surrender_report(target, accepted)
		return true, "queued"
	end
	target.outgoing[record.seq] = accepted
	self.prediction_outgoing_count = self.prediction_outgoing_count + 1
	if target.subject_pending then
		return true, "queued"
	end
	local sent = transport:send(self.host_peer_id, CHANNEL, accepted)
	if sent_reliably(self.host_peer_id, sent) then
		drop_outgoing(self, target, record.seq)
	end
	return true, not sent and "queued" or nil
end

function Runtime:append_prediction_snapshot(snapshot)
	for _, target in pairs(self.predicted_targets) do
		if alive(target.unit) and not self:is_detection_suppressed(target.unit) then
			for observer_key, feedback in pairs(target.feedback or {}) do
				local observer = self.core:observer(observer_key)
				if
					observer
					and alive(observer.unit)
					and (
						not feedback.observer_generation
						or observer.generation == feedback.observer_generation
							and observer.unit == feedback.observer_unit
					)
				then
					local entry = snapshot[observer.unit:key()]
						or { unit = observer.unit, kind = observer.kind, targets = {} }
					snapshot[observer.unit:key()] = entry
					local view = copy(feedback)
					view.unit, view.target_kind, view.target_id = target.unit, target.kind, target.id
					view.observer_kind, view.observer_id = observer.kind, observer.id
					local current = entry.targets[target.unit:key()]
					local decision = target.decision
					if
						not (
							decision
							and current
							and current.target_kind == decision.kind
							and current.target_id == decision.id
							and current.incarnation == decision.incarnation
							and current.epoch == decision.epoch
							and current.observer_kind == observer.kind
							and current.observer_id == observer.id
							and type(current.seq) == "number"
							and current.seq >= (feedback.seq or 0)
						)
					then
						entry.targets[target.unit:key()] = view
					end
				end
			end
		end
	end
	return snapshot
end

function Runtime:confirm_prediction(spec)
	if not self.core.is_host then
		local target = self:prediction_for_unit(spec.unit)
		if target and alive(spec.canonical_unit) then
			self.predicted_units[target.unit:key()] = nil
			target.unit = spec.canonical_unit
			self.predicted_units[target.unit:key()] = target
			return target
		end
		return nil, "unbound_prediction"
	end
	return self:_confirm_native_prediction(spec)
end

function Runtime:_receive_local_prediction_record(peer_id, record)
	if peer_id ~= self.host_peer_id then
		return nil, "not_host"
	end
	if record.op == "identity" then
		local old = self.core:prediction_identity()
		if
			old
			and (
				record.session_id < old.session_id
				or record.session_id == old.session_id and record.membership_id < old.membership_id
			)
		then
			return nil, "stale_prediction_identity"
		end
		if old and (old.session_id ~= record.session_id or old.membership_id ~= record.membership_id) then
			self:_reset_predictions()
		end
		self.core:set_prediction_identity(record.session_id, record.membership_id)
		return self.core:register_prediction_peer(self.local_peer_id, record.session_id, record.membership_id)
	end
	local identity = self.core:prediction_identity()
	if not identity or identity.session_id ~= record.session_id or identity.membership_id ~= record.membership_id then
		return nil, "stale_prediction_identity"
	end
	local target = self.predicted_targets[record.event_id]
	if record.op == "ack" then
		if target then
			if not record.accepted then
				local event = self.core:prediction(self.local_peer_id, target.event_id)
				self:_prediction_fallback(event)
				self:cancel_prediction_for_unit(target.unit, "observation_rejected")
				return nil, "observation_rejected"
			end
			drop_outgoing(self, target, record.seq)
		end
		return true
	elseif record.op ~= "decision" then
		return nil, "invalid_prediction_direction"
	end
	self.prediction_retries[record.event_id] = nil
	local applied, cancelled = self.core:apply_prediction_decision(self.local_peer_id, record)
	if not applied then
		return nil, cancelled
	end
	if not target then
		if record.accepted then
			local owner, epoch, current = self.core:get_owner(record.kind, record.id)
			local settled = applied.status == "accepted"
				and owner == self.local_peer_id
				and epoch == record.epoch
				and current.incarnation == record.incarnation
			local reply = identity_record(self, settled and "settled" or "cancel", record.event_id)
			reply.reason = not settled and "local_prediction_expired" or nil
			transport:send(self.host_peer_id, CHANNEL, reply)
		end
		return true
	end
	if record.accepted then
		return self:_promote_prediction(target, record)
	end
	for _, event in ipairs(cancelled or { applied }) do
		local child = self.predicted_targets[event.record.event_id]
		if child then
			self:_clear_prediction_view(child, record.reason)
		end
	end
	return true
end

function Runtime:receive_prediction_record(peer_id, incoming)
	local record, reason = Records.validate_prediction(incoming)
	if not record then
		return nil, reason
	end
	if not self:is_peer_capable(peer_id) then
		return nil, "unconfirmed_peer"
	end
	if not self.core.is_host then
		return self:_receive_local_prediction_record(peer_id, record)
	end
	return self:_receive_host_prediction_record(peer_id, record)
end

local function bind_subject(self, target, now)
	local observer = self:observer_identity(target.unit)
	if not observer or observer.generation == 0 then
		return false
	end
	local claim = self.core:bind_prediction_subject(self.local_peer_id, target.event_id, observer.generation)
	if not claim then
		return false
	end
	target.claim, target.subject_pending, target.next_retry = claim, false, now
	return true
end

function Runtime:update_predictions(now)
	now = now or self.network_time
	for _, target in pairs(self.predicted_targets) do
		if not self:is_active() or not control.allows_new_work(target.kind) then
			self:cancel_prediction_for_unit(target.unit, "inactive")
		end
	end
	self:_expire_npc_alert_marks()
	self.core:expire_predictions(now)
	for token, proof in pairs(self.prediction_proofs) do
		if now >= proof.deadline or not alive(proof.unit) then
			self.prediction_proofs[token] = nil
		end
	end
	if self.core.is_host then
		return self:_update_host_predictions(now)
	end
	self:retry_surrender_reports()
	for _, target in pairs(self.predicted_targets) do
		local event = self.core:prediction(self.local_peer_id, target.event_id)
		if not alive(target.unit) or not event then
			self:_clear_prediction_view(target, "removed")
		elseif target.accepted_deadline and now >= target.accepted_deadline then
			self:_prediction_fallback(event)
			self:cancel_prediction_for_unit(target.unit, "prediction_timeout")
		elseif event.status == "rejected" then
			self:cancel_prediction_for_unit(target.unit, event.reason)
		elseif target.decision and not target.canonical then
			self:_promote_prediction(target, target.decision)
		else
			if target.canonical then
				self:_finish_prediction(target)
			end
			if (not target.subject_pending or bind_subject(self, target, now)) and now >= target.next_retry then
				schedule_retry(target, now)
				if not target.decision and not target.claim_sent_rpc then
					target.claim_sent_rpc =
						sent_reliably(self.host_peer_id, transport:send(self.host_peer_id, CHANNEL, target.claim))
				end
				if not adapters.npc.surrender_pending(target.unit) then
					for seq, observation in pairs(target.outgoing) do
						local sent = transport:send(self.host_peer_id, CHANNEL, observation)
						if sent_reliably(self.host_peer_id, sent) then
							drop_outgoing(self, target, seq)
						end
					end
				end
			end
		end
	end
	for id, retry in pairs(self.prediction_retries) do
		if now >= retry.deadline then
			self.prediction_retries[id] = nil
		elseif not retry.sent_rpc and now >= retry.next_retry then
			schedule_retry(retry, now)
			retry.sent_rpc = sent_reliably(self.host_peer_id, transport:send(self.host_peer_id, CHANNEL, retry.record))
		end
	end
end

return Runtime
