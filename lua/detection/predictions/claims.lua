local Core, Records, object_key = ...

function Core:_reset_prediction_state()
	self.predictions = { peers = {} }
end

function Core:prediction_identity()
	return self.predictions.identity
end

function Core:prediction_peer_state(peer_id)
	return self.predictions.peers[peer_id]
end

function Core:prediction_peers()
	return self.predictions.peers
end

function Core:_forget_prediction_peer(peer_id)
	self.predictions.peers[peer_id] = nil
end
local LIMIT = { events = 128, depth = 32, observations = 1024, lifetime = 10, decisions = 512 }
Core.PREDICTION_LIMIT = LIMIT

local reject = Records.reject

function Core:set_prediction_identity(session_id, membership_id)
	local identity =
		Records.validate_prediction({ op = "identity", session_id = session_id, membership_id = membership_id })
	if not identity then
		return reject("invalid_prediction_identity")
	end
	self.predictions.identity = identity
	return identity
end

function Core:register_prediction_peer(peer_id, session_id, membership_id)
	if not self:_peer_eligible(peer_id) then
		return reject("ineligible_peer")
	end
	local identity =
		Records.validate_prediction({ op = "identity", session_id = session_id, membership_id = membership_id })
	if not identity then
		return reject("invalid_prediction_identity")
	end
	local old = self.predictions.peers[peer_id]
	if old and old.session_id == session_id and old.membership_id == membership_id then
		return old
	end
	local state = {
		session_id = session_id,
		membership_id = membership_id,
		events = {},
		decisions = {},
		last_event_id = 0,
		retired_id = 0,
		event_count = 0,
		observation_count = 0,
		decision_count = 0,
	}
	self.predictions.peers[peer_id] = state
	return state
end

function Core:prediction(peer_id, event_id)
	local state = self.predictions.peers[peer_id]
	return state and (state.events[event_id] or state.decisions[event_id])
end

function Core:_prediction_peer(peer_id, record)
	local state = self.predictions.peers[peer_id]
	if not state or state.session_id ~= record.session_id or state.membership_id ~= record.membership_id then
		return reject("stale_prediction_identity")
	end
	return state
end

function Core:begin_prediction(peer_id, record, now)
	if record.op ~= "claim" or not Records.valid_number(now) then
		return reject("invalid_prediction_claim")
	end
	if self.is_host and record.subject_generation == 0 and not record.native_token then
		return reject("subject_identity_pending")
	end
	local state, reason = self:_prediction_peer(peer_id, record)
	if not state then
		return reject(reason)
	end
	local existing = state.events[record.event_id] or state.decisions[record.event_id]
	if existing then
		return existing
	end
	if record.event_id <= state.retired_id then
		return reject("retired_prediction")
	end
	if record.event_id > state.last_event_id + LIMIT.events then
		return reject("prediction_sequence_gap")
	end
	if state.event_count >= LIMIT.events then
		return reject("prediction_capacity")
	end
	local depth = 1
	if record.parent_id then
		local parent = state.events[record.parent_id] or state.decisions[record.parent_id]
		if parent and parent.status == "rejected" then
			return reject("rejected_parent")
		end
		depth = parent and parent.depth + 1 or 1
		if depth > LIMIT.depth then
			return reject("prediction_depth")
		end
	else
		local owner, epoch, source = self:get_source_owner(record.source_kind, record.source_id)
		if
			(
				owner ~= peer_id
				or epoch ~= record.source_epoch
				or not source
				or source.incarnation ~= record.source_incarnation
			)
			and not (
				self.options.prediction_source_authorized
				and self.options.prediction_source_authorized(peer_id, record) == true
			)
		then
			return reject("unauthorized_source")
		end
	end
	local event = {
		record = record,
		status = "pending",
		depth = depth,
		deadline = now + LIMIT.lifetime,
		observations = {},
		observation_count = 0,
		watermark = 0,
		delivered_seq = 0,
	}
	state.events[record.event_id] = event
	state.event_count = state.event_count + 1
	state.last_event_id = math.max(state.last_event_id, record.event_id)
	return event
end

function Core:bind_prediction_subject(peer_id, event_id, generation)
	local event = self:prediction(peer_id, event_id)
	if
		self.is_host
		or peer_id ~= self.local_peer_id
		or not Records.valid_integer(generation)
		or generation == 0
		or not event
		or event.status ~= "pending"
		or event.record.subject_kind ~= "npc"
		or event.record.subject_generation ~= 0
		or event.record.native_token
	then
		return reject("invalid_prediction_subject")
	end
	event.record.subject_generation = generation
	return event.record
end

local function take_ready(state, event)
	local ready = {}
	local next_seq = event.delivered_seq + 1
	while event.observations and event.observations[next_seq] do
		ready[#ready + 1] = event.observations[next_seq]
		event.observations[next_seq] = nil
		event.observation_count = event.observation_count - 1
		state.observation_count = state.observation_count - 1
		event.delivered_seq = next_seq
		next_seq = next_seq + 1
	end
	return ready
end

function Core:receive_prediction_observation(peer_id, record)
	if record.op ~= "observe" then
		return reject("invalid_prediction_observation")
	end
	local state = self.predictions.peers[peer_id]
	local event = state.events[record.event_id] or state.decisions[record.event_id]
	if not event or event.status == "rejected" then
		return reject("missing_prediction")
	end
	local observer = self:observer(object_key(record.observer_kind, record.observer_id))
	if not observer or observer.generation ~= record.observer_generation then
		return reject("stale_observer")
	end
	local signature = event.status == "accepted" and event.decision.config_signature or event.record.config_signature
	if event.status == "accepted" and record.config_revision ~= event.decision.config_revision then
		if not (record.config_revision == 0 and signature and record.config_signature == signature) then
			return reject("stale_config")
		end
	end
	if signature and record.config_signature and record.config_signature ~= signature then
		return reject("stale_config")
	end
	if record.seq <= event.delivered_seq or event.observations[record.seq] then
		return event, {}, true
	end
	if state.observation_count >= LIMIT.observations then
		return reject("prediction_observation_capacity")
	end
	event.observations[record.seq] = record
	event.observation_count = event.observation_count + 1
	state.observation_count = state.observation_count + 1
	event.watermark = math.max(event.watermark, record.seq)
	return event, event.status == "accepted" and take_ready(state, event) or nil, false
end

local function retire(state, event_id, accepted, reason, decision)
	local event = state.events[event_id]
	if not event then
		return nil
	end
	state.events[event_id] = nil
	state.event_count = state.event_count - 1
	if not accepted then
		state.observation_count = state.observation_count - event.observation_count
	end
	event.status = accepted and "accepted" or "rejected"
	event.reason, event.decision = reason, decision
	if not accepted then
		event.observations = nil
	end
	state.decisions[event_id] = event
	state.decision_count = state.decision_count + 1
	if state.decision_count > LIMIT.decisions then
		local oldest = event_id
		for id in pairs(state.decisions) do
			if id < oldest then
				oldest = id
			end
		end
		local evicted = state.decisions[oldest]
		if evicted.status == "accepted" then
			state.observation_count = state.observation_count - evicted.observation_count
		end
		state.decisions[oldest] = nil
		state.decision_count = state.decision_count - 1
		state.retired_id = math.max(state.retired_id, oldest)
	end
	return event
end

function Core:confirm_prediction(peer_id, event_id, decision, superseded_config)
	local state = self.predictions.peers[peer_id]
	local event = state and state.events[event_id]
	if not event then
		return reject("missing_prediction")
	end
	if decision.op ~= "decision" or decision.accepted ~= true or decision.event_id ~= event_id then
		return reject("invalid_prediction_decision")
	end

	local parent = event.record.parent_id and self:prediction(peer_id, event.record.parent_id)
	if decision.owner_peer_id ~= peer_id or decision.kind ~= event.record.subject_kind then
		return reject("wrong_prediction_owner")
	end
	local depth = 1
	local ancestor = parent
	while ancestor do
		depth = depth + 1
		if depth > LIMIT.depth then
			return reject("prediction_depth")
		end
		ancestor = ancestor.record.parent_id and self:prediction(peer_id, ancestor.record.parent_id)
	end
	local target = self:target(object_key(decision.kind, decision.id))
	if not target or target.incarnation ~= decision.incarnation then
		return reject("unbound_prediction_target")
	end
	local owner, epoch = self:get_source_owner(decision.kind, decision.id)
	if owner ~= peer_id or epoch ~= decision.epoch then
		return reject("stale_prediction_owner")
	end
	local config = self:target_config(object_key(decision.kind, decision.id))
	local actual_signature = config and Records.prediction_config_signature(config)

	local superseded = superseded_config
		and decision.kind == "npc"
		and (event.record.cause == "npc_alert" or event.record.cause == "player_alert")
		and config
		and config.config_revision > decision.config_revision
		and superseded_config.kind == decision.kind
		and superseded_config.id == decision.id
		and superseded_config.incarnation == decision.incarnation
		and superseded_config.config_revision == config.config_revision
		and Records.prediction_config_signature(superseded_config) == actual_signature
		and event.record.config_signature == decision.config_signature
	if
		(self:target_config_revision(object_key(decision.kind, decision.id)) or 0) ~= decision.config_revision
		and not superseded
	then
		return reject("stale_prediction_config")
	end
	if
		event.record.config_signature
		and (event.record.config_signature ~= actual_signature or decision.config_signature ~= actual_signature)
		and not superseded
	then
		return reject("prediction_config_corrected")
	end
	local committed = retire(state, event_id, true, nil, decision)
	for seq in pairs(committed.observations) do
		if seq <= decision.watermark then
			committed.observations[seq] = nil
			committed.observation_count = committed.observation_count - 1
			state.observation_count = state.observation_count - 1
		end
	end
	committed.delivered_seq = decision.watermark
	return committed, take_ready(state, committed)
end

function Core:apply_prediction_decision(peer_id, record)
	if record.op ~= "decision" then
		return reject("invalid_prediction_decision")
	end
	local state, reason = self:_prediction_peer(peer_id, record)
	if not state then
		return reject(reason)
	end
	local existing = state.decisions[record.event_id]
	if existing then
		return existing
	end
	if not state.events[record.event_id] then
		return reject("missing_prediction")
	end
	if record.accepted then
		local event = retire(state, record.event_id, true, nil, record)
		event.observations = nil
		return event
	end
	local cancelled = self:reject_prediction(peer_id, record.event_id, record.reason or "rejected")
	return cancelled[1], cancelled
end

function Core:reject_prediction(peer_id, event_id, reason)
	local state = self.predictions.peers[peer_id]
	if state and state.decisions[event_id] then
		if state.decisions[event_id].status == "rejected" then
			return { state.decisions[event_id] }
		end
		return reject("already_committed")
	end
	if not state or not state.events[event_id] then
		return reject("missing_prediction")
	end
	local cancelled, queue = {}, { event_id }
	local index = 1
	while index <= #queue do
		local id = queue[index]
		for child_id, child in pairs(state.events) do
			if child.record.parent_id == id then
				queue[#queue + 1] = child_id
			end
		end
		local event = retire(state, id, false, reason or "cancelled")
		cancelled[#cancelled + 1] = event
		index = index + 1
	end
	return cancelled
end

function Core:expire_predictions(now)
	if not Records.valid_number(now) then
		return nil
	end
	local expired
	for peer_id, state in pairs(self.predictions.peers) do
		for id, event in pairs(state.events) do
			if now >= event.deadline and state.events[id] then
				local cancelled = self:reject_prediction(peer_id, id, "expired")
				for _, item in ipairs(cancelled) do
					expired = expired or {}
					expired[#expired + 1] = item
				end
			end
		end
	end
	return expired
end

return Core
