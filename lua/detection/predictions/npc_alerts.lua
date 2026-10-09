local Runtime, State, alive, control, adapters = ...
local key = State.object_key

function Runtime:_npc_alert_mark(unit)
	local mark = alive(unit) and self.npc_alert_marks[unit:key()]
	if not mark or mark.unit ~= unit or self.network_time >= mark.deadline then
		return nil
	end
	local owner, epoch, source = self.core:get_source_owner(mark.source_kind, mark.source_id)
	if
		not control.allows_new_work(mark.source_kind)
		or owner ~= self.local_peer_id
		or epoch ~= mark.source_epoch
		or not source
		or source.incarnation ~= mark.source_incarnation
	then
		return nil
	end
	return mark
end

function Runtime:_mark_npc_alert(spec)
	local existing = self:_npc_alert_mark(spec.unit)
	if existing then
		return existing
	end
	local source = self:_prediction_source(spec)
	if not source or source.prediction or not control.allows_new_work(source.kind) then
		return nil, "unauthorized_source"
	end
	local owner, epoch, record = self.core:get_source_owner(source.kind, source.id)
	if owner ~= self.local_peer_id or not record then
		return nil, "unauthorized_source"
	end
	local mark = {
		unit = spec.unit,
		source_kind = source.kind,
		source_id = source.id,
		source_incarnation = record.incarnation,
		source_epoch = epoch,
		feature = spec.mark_feature or "intimidation",
		deadline = self.network_time + self.core.PREDICTION_LIMIT.lifetime,
	}
	self.npc_alert_marks[spec.unit:key()] = mark
	return mark
end

function Runtime:current_npc_alert(unit)
	local mark = self:_npc_alert_mark(unit)
	if mark then
		return {
			status = "local",
			age = self.network_time - (mark.deadline - self.core.PREDICTION_LIMIT.lifetime),
		}
	end
	local target = self:prediction_for_unit(unit)
	local event, claim
	if target then
		event = self.core:prediction(self.local_peer_id, target.event_id)
		claim = target.claim
	else
		target = self:target_for_unit(unit)
		if target and target.kind == "npc" and target.unit == unit then
			local alert_event_id = self.npc_alert_events[target]
			event = alert_event_id and self.core:prediction(self.local_peer_id, alert_event_id)
			claim = event and event.record
		end
	end
	local identity = self.core:prediction_identity()
	if not target or target.kind ~= "npc" or target.unit ~= unit then
		return nil, "missing_npc_alert"
	end
	if
		not claim
		or not identity
		or claim.session_id ~= identity.session_id
		or claim.membership_id ~= identity.membership_id
		or claim.subject_kind ~= "npc"
		or claim.cause ~= "npc_alert" and claim.cause ~= "player_alert"
		or not event
		or event.status ~= "pending" and event.status ~= "accepted"
		or self.network_time >= (event.deadline or 0)
	then
		return nil, "stale_npc_alert"
	end
	if event.status == "pending" then
		local observer = self:observer_identity(unit)
		if
			claim.subject_id ~= unit:id()
			or claim.subject_generation ~= 0 and (not observer or observer.generation ~= claim.subject_generation)
		then
			return nil, "stale_npc_subject"
		end
		local source_claim = claim
		for _ = 1, self.core.PREDICTION_LIMIT.depth do
			if not source_claim.parent_id then
				break
			end
			local parent = self.core:prediction(self.local_peer_id, source_claim.parent_id)
			if not parent or parent.status == "rejected" or self.network_time >= parent.deadline then
				return nil, "stale_npc_ancestor"
			end
			source_claim = parent.record
		end
		if source_claim.parent_id then
			return nil, "npc_ancestor_depth"
		end
		local owner, epoch, source = self.core:get_source_owner(source_claim.source_kind, source_claim.source_id)
		if
			not control.allows_new_work(source_claim.source_kind)
			or owner ~= self.local_peer_id
			or epoch ~= source_claim.source_epoch
			or not source
			or source.incarnation ~= source_claim.source_incarnation
		then
			return nil, "stale_npc_source"
		end
	else
		local canonical, decision = target.canonical or target, event.decision
		local owner, epoch = self.core:get_source_owner(canonical.kind, canonical.id)
		if
			not decision
			or decision.kind ~= "npc"
			or claim.config_signature ~= decision.config_signature
			or self.core:target_config_revision(key("npc", decision.id)) ~= decision.config_revision
			or canonical.unit ~= unit
			or decision.id ~= canonical.id
			or decision.incarnation ~= canonical.incarnation
			or decision.epoch ~= epoch
			or owner ~= self.local_peer_id
		then
			return nil, "stale_npc_decision"
		end
	end
	return {
		event_id = target.event_id or self.npc_alert_events[target],
		status = event.status,
		age = self.network_time - (event.deadline - self.core.PREDICTION_LIMIT.lifetime),
	}
end

function Runtime:_retain_npc_alert(target)
	if target.kind == "npc" and (target.cause == "npc_alert" or target.cause == "player_alert") then
		self.npc_alert_events[target.canonical] = target.event_id
	end
end

function Runtime:_cancel_npc_alert(unit, reason)
	local canonical = alive(unit) and self.target_by_unit[unit:key()]
	if canonical and canonical.unit == unit then
		self.npc_alert_events[canonical] = nil
	end
	local mark = alive(unit) and self.npc_alert_marks[unit:key()]
	if mark then
		self.npc_alert_marks[unit:key()] = nil
		if adapters.npc and adapters.npc.cancel_prediction then
			adapters.npc.cancel_prediction(unit, reason)
		end
	end
end

function Runtime:_expire_npc_alert_marks()
	for unit_key, mark in pairs(self.npc_alert_marks) do
		local movement = alive(mark.unit) and mark.unit:movement()
		if movement and not movement:cool() then
			self.npc_alert_marks[unit_key] = nil
		elseif not self:_npc_alert_mark(mark.unit) or not control.allows_new_work(mark.feature) then
			self.npc_alert_marks[unit_key] = nil
			if movement and adapters.npc and adapters.npc.cancel_prediction then
				adapters.npc.cancel_prediction(mark.unit, "expired")
			end
		end
	end
end

return Runtime
