local Runtime, Records, State, alive, copy, adapters, transport, restoring_call = ...
local key = State.object_key
local CHANNEL = transport.channel.prediction
local identity_record, drop_all_outgoing = Runtime._prediction_record, Runtime._drop_prediction_outgoing

local function remap_prediction(self, old_unit, new_unit, handler, old_key, new_key, canonical)
	handler = self:_decorate_attention({ { unit = new_unit, handler = handler } })[1].handler
	for _, adapter in pairs(adapters) do
		if adapter.remap_prediction then
			adapter.remap_prediction(old_unit, new_unit, handler, old_key, new_key, canonical)
		end
	end
end

function Runtime:refresh_prediction_reports(unit)
	for _, adapter in pairs(adapters) do
		if adapter.refresh_prediction_reports then
			adapter.refresh_prediction_reports(unit)
		end
	end
end

local function carry_feedback(self, target)
	local decision = target.decision
	if not decision then
		return
	end
	for observer_key, feedback in pairs(target.feedback or {}) do
		local observer = self.core:observer(observer_key)
		local current = self.core:observation(observer_key .. ">" .. key(decision.kind, decision.id))
		if
			observer
			and (not feedback.observer_generation or feedback.observer_generation == observer.generation and feedback.observer_unit == observer.unit)
			and (
				not current
				or current.incarnation ~= decision.incarnation
				or current.epoch ~= decision.epoch
				or (current.seq or 0) <= (feedback.seq or 0)
			)
		then
			self.core:record_local_observation({
				target_kind = decision.kind,
				target_id = decision.id,
				incarnation = decision.incarnation,
				epoch = decision.epoch,
				observer_kind = observer.kind,
				observer_id = observer.id,
				observer_generation = observer.generation,
				seq = feedback.seq,
				transition = feedback.transition,
				value = feedback.value,
			})
			if feedback.notice_progress and not feedback.cleared then
				self.core:set_local_notice_progress(
					observer_key,
					key(decision.kind, decision.id),
					feedback.notice_progress
				)
			end
			local seq_key = observer_key .. ">" .. key(decision.kind, decision.id) .. "@" .. decision.epoch
			self.local_report_seq[seq_key] = math.max(self.local_report_seq[seq_key] or 0, feedback.seq or 0)
		end
	end
end

function Runtime:update_prediction_attention(unit, config)
	local target = self:prediction_for_unit(unit)
	if not target or not config then
		return false
	end
	config = adapters.npc.surrender_attention_config(unit, config)
	local signature = Records.prediction_config_signature(config)
	if signature == Records.prediction_config_signature(target.attention_config or target.config) then
		return true
	end
	local handler = adapters.world_target.prediction_attention(unit, config)
	if not handler then
		return false
	end
	target.attention, target.attention_config = handler, copy(config)
	local canonical = target.canonical or target
	local target_key = key(canonical.kind, canonical.id)
	remap_prediction(self, unit, unit, handler, target_key, target_key, canonical)
	handler:_call_listeners()
	return true
end

local function while_promoting(self, field, value, fn, ...)
	self[field] = value
	return restoring_call(function()
		self[field] = nil
	end, fn, ...)
end

function Runtime:_promote_prediction(target, decision)
	target.accepted_deadline = target.accepted_deadline or self.network_time + 10
	if decision.config_signature ~= target.claim.config_signature then
		self:cancel_prediction_for_unit(target.unit, "prediction_config_corrected")
		return nil, "prediction_config_corrected"
	end
	local canonical = self.core:target(key(decision.kind, decision.id))
	if not canonical then
		local unit = self.prediction_bindings[key(decision.kind, decision.id)]
		if not unit and target.claim.native_token == nil and target.unit:id() == decision.id then
			unit = target.unit
		end
		if alive(unit) then
			canonical = while_promoting(
				self,
				"prediction_promoting",
				unit,
				self.register_target,
				self,
				decision.kind,
				decision.id,
				unit,
				{ incarnation = decision.incarnation }
			)
		end
	end
	if not canonical or not alive(canonical.unit) then
		target.decision = decision
		return nil, "canonical_unit_pending"
	end
	if canonical.unit ~= target.unit and target.claim.native_token == nil then
		return nil, "replaced_prediction_unit"
	end
	local _, current_epoch = self.core:get_owner(decision.kind, decision.id)
	if
		canonical.incarnation ~= 0 and canonical.incarnation ~= decision.incarnation
		or current_epoch and current_epoch > decision.epoch
	then
		self:cancel_prediction_for_unit(target.unit, "stale_prediction_owner")
		return nil, "stale_prediction_owner"
	end
	while_promoting(self, "prediction_promoting", canonical.unit, self.core.apply_owner_state, self.core, decision)
	if canonical.incarnation ~= decision.incarnation then
		return nil, "stale_prediction_target"
	end
	target.decision = decision
	local config = copy(target.config)
	config.kind, config.id, config.incarnation = decision.kind, decision.id, decision.incarnation
	config.config_revision = decision.config_revision

	local current_config = self.core:target_config(key(decision.kind, decision.id))
	if not current_config or current_config.config_revision <= decision.config_revision then
		while_promoting(self, "prediction_promoting_target", target, self.core.apply_target_config, self.core, config)
	end
	if not target.identity_remapped then
		local old_unit = target.unit
		local handler = target.attention
		if canonical.unit ~= old_unit then
			handler = adapters.world_target.prediction_attention(canonical.unit, target.config)
		end
		if not handler then
			return nil, "canonical_attention_pending"
		end
		remap_prediction(
			self,
			old_unit,
			canonical.unit,
			handler,
			key(target.kind, target.id),
			key(decision.kind, decision.id),
			canonical
		)
		target.identity_remapped = true
		if canonical.unit ~= old_unit then
			self.predicted_units[old_unit:key()] = nil
			target.unit, target.attention = canonical.unit, handler
			self.predicted_units[canonical.unit:key()] = target
		end
	end
	for _, observation in pairs(target.observations) do
		local observer_key = key(observation.observer_kind, observation.observer_id)
		local observer = self.core:observer(observer_key)
		local current = self.core:observation(observer_key .. ">" .. key(decision.kind, decision.id))
		if
			observer
			and observer.generation == observation.observer_generation
			and (
				not current
				or current.incarnation ~= decision.incarnation
				or current.epoch ~= decision.epoch
				or current.seq <= observation.seq
			)
		then
			self.core:record_local_observation({
				target_kind = decision.kind,
				target_id = decision.id,
				incarnation = decision.incarnation,
				epoch = decision.epoch,
				observer_kind = observation.observer_kind,
				observer_id = observation.observer_id,
				observer_generation = observation.observer_generation,
				config_revision = decision.config_revision,
				seq = observation.seq,
				transition = observation.transition,
				value = observation.value,
			})

			local feedback = target.feedback and target.feedback[observer_key]
			if feedback and feedback.notice_progress then
				self.core:set_local_notice_progress(
					observer_key,
					key(decision.kind, decision.id),
					feedback.notice_progress
				)
			end
		end
		local seq_key = observer_key .. ">" .. key(decision.kind, decision.id) .. "@" .. decision.epoch
		self.local_report_seq[seq_key] = math.max(self.local_report_seq[seq_key] or 0, observation.seq)
	end

	target.decision, target.canonical = decision, canonical
	carry_feedback(self, target)
	if current_config and current_config.config_revision > decision.config_revision then
		self:update_prediction_attention(target.unit, current_config)
	end
	transport:send(self.host_peer_id, CHANNEL, identity_record(self, "settled", target.event_id))
	return canonical
end

function Runtime:_finish_prediction(target)
	if not target.canonical or adapters.npc.surrender_pending(target.unit) then
		return false
	end
	local config = self.core:target_config(key(target.canonical.kind, target.canonical.id))
	if config and target.decision and config.config_revision > target.decision.config_revision then
		self:update_prediction_attention(target.unit, config)
	end

	if next(target.outgoing) then
		return false
	end
	if
		target.attention_config
		and Records.prediction_config_signature(config)
			~= Records.prediction_config_signature(target.attention_config)
	then
		return false
	end
	local world_adapter = adapters.world_target
	if
		not config
		or not world_adapter
		or not world_adapter.apply_config
		or world_adapter.apply_config(target.unit, config) == false
	then
		return false
	end
	local native_config = world_adapter.config(target.unit)

	if Records.prediction_config_signature(native_config) ~= Records.prediction_config_signature(config) then
		return false
	end
	local handler = world_adapter.attention_handler(target.unit)
	if not handler then
		return false
	end
	remap_prediction(
		self,
		target.unit,
		target.unit,
		handler,
		key(target.kind, target.id),
		key(target.canonical.kind, target.canonical.id),
		target.canonical
	)
	if Records.prediction_config_signature(config) ~= target.claim.config_signature then
		world_adapter.refresh_attention(target.unit)
	end
	self:_retain_npc_alert(target)
	drop_all_outgoing(self, target)
	carry_feedback(self, target)
	self.predicted_targets[target.event_id], self.predicted_keys[key(target.kind, target.id)] = nil, nil
	self.predicted_units[target.unit:key()] = nil
	if Records.prediction_config_signature(config) ~= target.claim.config_signature then
		self:refresh_prediction_reports(target.unit)
	end
	return true
end

return Runtime
