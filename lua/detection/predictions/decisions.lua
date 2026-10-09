local Runtime, Records, State, copy, transport, adapters = ...
local key = State.object_key
local proof_key = Records.prediction_proof_key
local CHANNEL = transport.channel.prediction

local schedule_retry, sent_reliably = Runtime._schedule_prediction_retry, Runtime._sent_reliably

function Runtime:_forget_peer_predictions(peer_id)
	self.prediction_unsettled[peer_id] = nil
	for token, proof in pairs(self.prediction_proofs) do
		if proof.peer_id == peer_id then
			self.prediction_proofs[token] = nil
		end
	end
end

local function reject_tree(self, peer_id, record, reason)
	for _, child in ipairs(self.core:reject_prediction(peer_id, record.event_id, reason) or {}) do
		self:_prediction_decision(peer_id, child, false, reason)
	end
	return nil, reason
end

function Runtime:_prediction_fallback(event, keep_root)
	local decision = event and event.decision
	if not self.core.is_host or not decision then
		return
	end
	local target = keep_root and self.core:target(key(decision.kind, decision.id))
	if target and self:alert_root(target.unit) == decision.owner_peer_id then
		return
	end
	local owner, epoch, record = self.core:get_owner(decision.kind, decision.id)
	if
		owner == decision.owner_peer_id
		and epoch == decision.epoch
		and record
		and record.incarnation == decision.incarnation
		and (self.core:target_config_revision(key(decision.kind, decision.id)) or 0) == decision.config_revision
	then
		self.core:assign_owner(decision.kind, decision.id, self.host_peer_id)
		self:mark_state_dirty()
	end
end

function Runtime:_prediction_decision(peer_id, event, accepted, reason)
	local record = copy(event.decision or event.record)
	record.op, record.accepted, record.reason = "decision", accepted, reason
	record.watermark = event.decision and event.decision.watermark or 0
	local sent = transport:send(peer_id, CHANNEL, record)
	return record, sent_reliably(peer_id, sent)
end

function Runtime:_apply_prediction_observation(peer_id, event, record)
	local decision = event.decision
	local report = {
		target_kind = decision.kind,
		target_id = decision.id,
		incarnation = decision.incarnation,
		epoch = decision.epoch,
		observer_kind = record.observer_kind,
		observer_id = record.observer_id,
		observer_generation = record.observer_generation,
		config_revision = decision.config_revision,
		seq = record.seq,
		transition = record.transition,
		value = record.value,
	}
	local accepted, reason = self.core:receive_report_record(peer_id, report)
	local ack = copy(record)
	local superseded = false
	if reason == "stale_config" then
		local owner, epoch, current = self.core:get_owner(decision.kind, decision.id)
		superseded = owner == peer_id
			and epoch == decision.epoch
			and current ~= nil
			and current.incarnation == decision.incarnation
			and (self.core:target_config_revision(key(decision.kind, decision.id)) or 0) > decision.config_revision
	end

	ack.op, ack.accepted =
		"ack", accepted ~= nil or reason == "stale_sequence" or reason == "observer_alerted" or superseded
	if not ack.accepted or transport:mode(peer_id) ~= "rpc" then
		transport:send(peer_id, CHANNEL, ack)
	end
	if not ack.accepted then
		self:_prediction_fallback(event)
		local unsettled = self.prediction_unsettled[peer_id]
		if unsettled then
			unsettled[event.record.event_id] = nil
		end
	end
	return accepted, reason
end

function Runtime:_try_prediction(peer_id, event)
	if event.status ~= "pending" then
		return self:_prediction_decision(peer_id, event, event.status == "accepted", event.reason)
	end
	local record = event.record
	if not self.core:can_own(peer_id, record.subject_kind) then
		return reject_tree(self, peer_id, record, "category_disabled")
	end
	local proof = self.prediction_proofs[proof_key(record)]
	if
		not proof
		and record.subject_kind == "npc"
		and (record.cause == "npc_alert" or record.cause == "player_alert")
	then
		local parent = record.parent_id and self.core:prediction(peer_id, record.parent_id)
		local decision = parent and parent.decision
		local source_kind = decision and decision.kind or record.source_kind
		local source_id = decision and decision.id or record.source_id
		local incarnation = decision and decision.incarnation or record.source_incarnation
		local source = source_kind and self.core:target(key(source_kind, source_id))
		if source and source.incarnation == incarnation and self:is_detection_suppressed(source.unit) then
			return reject_tree(self, peer_id, record, "source_suspended")
		end
	end
	if not proof then
		return nil, "native_event_pending"
	end
	local target = self.core:target(key(proof.kind, proof.id))
	if not target or target.unit ~= proof.unit or target.incarnation ~= proof.incarnation then
		return nil, "stale_native_event"
	end
	if self:_native_owner(proof) ~= peer_id then
		return nil, "native_owner"
	end
	local config = self.core:target_config(key(target.kind, target.id))
	local native = target.kind == "npc" and adapters.world_target.config(proof.unit)

	local superseded = target.kind == "npc"
		and proof.config_signature == record.config_signature
		and config
		and config.config_revision > proof.config_revision
		and Records.prediction_config_signature(native) == Records.prediction_config_signature(config)
	if record.config_signature ~= Records.prediction_config_signature(config) and not superseded then
		return reject_tree(self, peer_id, record, "prediction_config_corrected")
	end
	if superseded then
		local pending = self.core:pending_handoff(key(target.kind, target.id))
		local owner = pending and pending.owner_peer_id or self.core:get_owner(target.kind, target.id)
		if owner ~= peer_id then
			return reject_tree(self, peer_id, record, "stale_prediction_owner")
		end
	end
	if target.kind == "npc" then
		if not native or not superseded and Records.prediction_config_signature(native) ~= record.config_signature then
			return nil, "native_config_pending"
		end
	end
	if self.core:detection_advanced(key(target.kind, target.id), target.incarnation) then
		return reject_tree(self, peer_id, record, "native_detection_advanced")
	end
	local unsettled = self.prediction_unsettled[peer_id]
	local unsettled_count = 0
	for _ in pairs(unsettled or {}) do
		unsettled_count = unsettled_count + 1
	end
	if unsettled_count >= self.core.PREDICTION_LIMIT.events then
		return nil, "prediction_unsettled_capacity"
	end
	local owner = self.core:prepare_owner(target.kind, target.id, peer_id, self.network_time, 10)
	if not owner or owner.owner_peer_id ~= peer_id then
		return nil, "ineligible_prediction_owner"
	end
	if owner.pending then
		self.core:authorize_handoff_reports(owner)
	end
	local decision = {
		op = "decision",
		session_id = record.session_id,
		membership_id = record.membership_id,
		event_id = record.event_id,
		accepted = true,
		kind = target.kind,
		id = target.id,
		incarnation = target.incarnation,
		epoch = owner.epoch,
		owner_peer_id = peer_id,
		config_revision = superseded and proof.config_revision or config and config.config_revision or 0,
		config_signature = record.config_signature,
		watermark = 0,
	}
	local committed, reports =
		self.core:confirm_prediction(peer_id, record.event_id, decision, superseded and config or nil)
	if not committed then
		if owner.pending then
			self.core:cancel_prepared_owner(owner)
		end
		return nil, reports
	end
	if owner.pending then
		self.core:commit_prepared_owner(owner)
	end
	if target.kind == "npc" and not self:alert_root(target.unit) then
		self:_attach_alert_root(target, peer_id)
	elseif target.kind ~= "npc" then
		self:_inherit_alert_root(target, peer_id)
	end
	self:_release_detection_hold(target.unit)
	self.prediction_stats.decisions = self.prediction_stats.decisions + 1
	self.prediction_unsettled[peer_id] = self.prediction_unsettled[peer_id] or {}
	self.prediction_unsettled[peer_id][record.event_id] = {
		event = committed,
		deadline = self.network_time + 10,
		next_retry = self.network_time + 1,
	}
	local _, sent_rpc = self:_prediction_decision(peer_id, committed, true)
	self.prediction_unsettled[peer_id][record.event_id].sent_rpc = sent_rpc
	for _, observation in ipairs(reports or {}) do
		self:_apply_prediction_observation(peer_id, committed, observation)
	end
	self:mark_state_dirty()
	return committed
end

function Runtime:_receive_host_prediction_record(peer_id, record)
	local peer = self.core:prediction_peer_state(peer_id)
	if not peer or peer.session_id ~= record.session_id or peer.membership_id ~= record.membership_id then
		return nil, "stale_prediction_identity"
	end
	if record.op == "claim" then
		local event, error_code = self.core:begin_prediction(peer_id, record, self.network_time)
		if not event then
			self:_prediction_decision(peer_id, { record = record }, false, error_code)
			return nil, error_code
		end
		self:_try_prediction(peer_id, event)
		return true
	elseif record.op == "observe" then
		local event, ready, duplicate = self.core:receive_prediction_observation(peer_id, record)
		if not event then
			return nil, ready
		end
		for _, observation in ipairs(ready or {}) do
			self:_apply_prediction_observation(peer_id, event, observation)
		end
		if duplicate and event.status == "accepted" and record.seq <= event.delivered_seq then
			local decision = event.decision
			local owner, epoch, current = self.core:get_owner(decision.kind, decision.id)
			local ack = copy(record)
			ack.op = "ack"
			ack.accepted = current ~= nil
				and owner == decision.owner_peer_id
				and epoch == decision.epoch
				and current.incarnation == decision.incarnation
			transport:send(peer_id, CHANNEL, ack)
		end
		return true
	elseif record.op == "cancel" then
		local current = self.core:prediction(peer_id, record.event_id)
		if current and current.status ~= "pending" then
			self:_prediction_fallback(current, true)
			local unsettled = self.prediction_unsettled[peer_id]
			if unsettled then
				unsettled[record.event_id] = nil
			end
			self:_prediction_decision(peer_id, current, false, "detector_cancelled")
			return true
		end
		local cancelled = self.core:reject_prediction(peer_id, record.event_id, record.reason)
		for _, event in ipairs(cancelled or {}) do
			self:_prediction_decision(peer_id, event, false, record.reason)
		end
		return cancelled
	elseif record.op == "settled" then
		local event = self.core:prediction(peer_id, record.event_id)
		if not event or event.status ~= "accepted" then
			return nil, "missing_prediction"
		end
		local unsettled = self.prediction_unsettled[peer_id]
		if unsettled then
			unsettled[record.event_id] = nil
		end
		return event
	end
	return nil, "invalid_prediction_direction"
end

function Runtime:_update_host_predictions(now)
	for peer_id, pending in pairs(self.prediction_unsettled) do
		for id, entry in pairs(pending) do
			if now >= entry.deadline then
				self:_prediction_fallback(entry.event, true)
				pending[id] = nil
			elseif not entry.sent_rpc and now >= entry.next_retry then
				schedule_retry(entry, now)
				local _, sent_rpc = self:_prediction_decision(peer_id, entry.event, true)
				entry.sent_rpc = sent_rpc
			end
		end
	end
	for peer_id, peer in pairs(self.core:prediction_peers()) do
		for _, event in pairs(peer.events) do
			self:_try_prediction(peer_id, event)
		end
	end
	self:_prune_alert_roots()
	return
end

return Runtime
