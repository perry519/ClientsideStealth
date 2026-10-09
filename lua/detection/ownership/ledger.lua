local Core, Records, object_key, copy_record = ...
local reject = Records.reject
local valid_integer = Records.valid_integer
local valid_number = Records.valid_number

function Core:_reset_ownership()
	local previous = self.ownership
	self.ownership = { ledger = {}, pending = {}, next_handoff_id = previous and previous.next_handoff_id or 0 }
end

function Core:owner_record(key)
	return self.ownership.ledger[key]
end

function Core:pending_handoff(key)
	return self.ownership.pending[key]
end

function Core:owners()
	return self.ownership.ledger
end

function Core:pending_handoffs()
	return self.ownership.pending
end

function Core:_set_owner_record(key, record)
	self.ownership.ledger[key] = record
end

function Core:_drop_owner(key)
	local ownership = self.ownership
	local old = ownership.ledger[key]
	ownership.ledger[key], ownership.pending[key] = nil, nil
	return old
end

function Core:_bind_owner_incarnation(key, incarnation)
	local current = self.ownership.ledger[key]
	if current and current.incarnation == 0 then
		current.incarnation = incarnation
	end
end

function Core:_peer_eligible(peer_id)
	return valid_integer(peer_id)
		and peer_id > 0
		and (not self.options.peer_eligible or self.options.peer_eligible(peer_id) == true)
end

function Core:can_own(peer_id, kind)
	return self:_peer_eligible(peer_id)
		and (not self.options.owner_eligible or self.options.owner_eligible(peer_id, kind) == true)
end

function Core:get_owner(kind, id)
	local record = self.ownership.ledger[object_key(kind, id)]
	return record and record.owner_peer_id, record and record.epoch, record
end

function Core:effective_owner(key)
	local pending = self.ownership.pending[key]
	return pending and pending.reports_authorized and pending or self.ownership.ledger[key]
end

function Core:get_source_owner(kind, id)
	local record = self:effective_owner(object_key(kind, id))
	return record and record.owner_peer_id, record and record.epoch, record
end

function Core:assign_owner(kind, id, owner_peer_id)
	local key = object_key(kind, id)
	if not self:target(key) then
		return reject("missing_target")
	end
	local owner = self:can_own(owner_peer_id, kind) and owner_peer_id or self.host_peer_id
	local old = self.ownership.ledger[key]
	if not old then
		return reject("missing_owner")
	end
	local pending = self.ownership.pending[key]
	if old.owner_peer_id == owner and not pending then
		return old
	end
	local target = self:target(key)
	if owner ~= self.host_peer_id and kind ~= "player" and kind ~= "vehicle" and not self:target_config(key) then
		owner = self.host_peer_id
	end
	local record = {
		kind = kind,
		id = id,
		incarnation = target.incarnation,
		owner_peer_id = owner,
		epoch = pending and (owner == pending.owner_peer_id and pending.epoch or pending.epoch + 1) or old.epoch + 1,
	}
	self.ownership.ledger[key] = record
	self.ownership.pending[key] = nil
	if self.options.on_cleanup then
		self.options.on_cleanup(copy_record(old), copy_record(record))
	end
	if self.options.on_owner then
		self.options.on_owner(copy_record(record), copy_record(old))
	end
	return record
end

function Core:prepare_owner(kind, id, owner_peer_id, now, timeout, policy)
	local key = object_key(kind, id)
	local target, current = self:target(key), self.ownership.ledger[key]
	if not target or not current then
		return reject("missing_target")
	end
	local owner = self:can_own(owner_peer_id, kind) and owner_peer_id or self.host_peer_id
	if owner == self.host_peer_id or owner == current.owner_peer_id then
		return self:assign_owner(kind, id, owner)
	end
	if kind ~= "player" and kind ~= "vehicle" and not self:target_config(key) then
		return self:assign_owner(kind, id, self.host_peer_id)
	end
	local pending = self.ownership.pending[key]
	if pending and pending.owner_peer_id == owner and pending.incarnation == target.incarnation then
		if policy and policy.persistent then
			pending.persistent = true
			pending.fixed_activation = policy.fixed_activation == true
		end
		return pending
	end
	if pending then
		self:assign_owner(kind, id, current.owner_peer_id)
		current = self.ownership.ledger[key]
	end
	self.ownership.next_handoff_id = self.ownership.next_handoff_id + 1
	pending = {
		handoff_id = self.ownership.next_handoff_id,
		kind = kind,
		id = id,
		incarnation = target.incarnation,
		owner_peer_id = owner,
		epoch = current.epoch + 1,
		deadline = valid_number(now) and valid_number(timeout) and now + timeout or nil,
		pending = true,
		fixed_activation = policy and policy.fixed_activation == true or false,
		persistent = policy and policy.persistent == true or false,
	}
	self.ownership.pending[key] = pending
	return pending
end

function Core:authorize_handoff_reports(handoff)
	if not self.is_host then
		return reject("not_host")
	end
	local pending = self:_matching_handoff(handoff)
	if not pending or not self:can_own(pending.owner_peer_id, pending.kind) then
		return reject("stale_handoff")
	end
	pending.reports_authorized = true
	return true
end

function Core:handoff_needs_refresh(handoff)
	local pending = self:_matching_handoff(handoff)
	return pending ~= nil
		and not pending.fixed_activation
		and (self:observation_revision(object_key(handoff.kind, handoff.id)) or 0) ~= handoff.observation_revision
end

function Core:commit_prepared_owner(handoff)
	local pending = self:_matching_handoff(handoff)
	if not pending or not self:can_own(pending.owner_peer_id, pending.kind) then
		return reject("stale_handoff")
	end
	return self:assign_owner(pending.kind, pending.id, pending.owner_peer_id)
end

function Core:_matching_handoff(handoff)
	if not handoff then
		return nil
	end
	local pending = self.ownership.pending[object_key(handoff.kind, handoff.id)]
	if
		pending
		and pending.handoff_id == handoff.handoff_id
		and pending.incarnation == handoff.incarnation
		and pending.epoch == handoff.epoch
		and pending.owner_peer_id == handoff.owner_peer_id
	then
		return pending
	end
	return nil
end

function Core:cancel_prepared_owner(handoff)
	local pending = self:_matching_handoff(handoff)
	if not pending then
		return false
	end
	self:assign_owner(
		pending.kind,
		pending.id,
		self.ownership.ledger[object_key(pending.kind, pending.id)].owner_peer_id
	)
	return true
end

function Core:is_handoff_persistent(handoff)
	local pending = self:_matching_handoff(handoff)
	return pending ~= nil and pending.persistent == true
end

function Core:cancel_peer_handoffs(peer_id)
	local cancelled = {}
	for key, pending in pairs(self.ownership.pending) do
		if pending.owner_peer_id == peer_id then
			self:assign_owner(pending.kind, pending.id, self.ownership.ledger[key].owner_peer_id)
			cancelled[#cancelled + 1] = copy_record(pending)
		end
	end
	return cancelled
end

function Core:expire_handoffs(now)
	local expired = {}
	if not valid_number(now) then
		return expired
	end
	for key, pending in pairs(self.ownership.pending) do
		if not pending.persistent and pending.deadline and now >= pending.deadline then
			self:assign_owner(pending.kind, pending.id, self.ownership.ledger[key].owner_peer_id)
			expired[#expired + 1] = copy_record(pending)
		end
	end
	return expired
end

function Core:peer_lost(peer_id)
	self:_forget_prediction_peer(peer_id)
	local changed = {}
	for _, record in pairs(self.ownership.ledger) do
		if record.owner_peer_id == peer_id then
			changed[#changed + 1] = self:assign_owner(record.kind, record.id, self.host_peer_id)
		end
	end
	return changed
end

function Core:is_owned(kind, id, peer_id)
	local owner = self:effective_owner(object_key(kind, id))
	return (owner and owner.owner_peer_id or self.host_peer_id) == peer_id
end

return Core
