local Runtime, State, engine_alive, copy_record, adapters, camera_hud = ...
local object_key = State.object_key

function Runtime:_on_owner(record)
	local promoting = self.core:target(object_key(record.kind, record.id))
	if promoting and (self.prediction_promoting == promoting.unit or self:prediction_for_unit(promoting.unit)) then
		return
	end
	if record.owner_peer_id ~= self.local_peer_id then
		return
	end
	local target = self.core:target(object_key(record.kind, record.id))
	if not target or record.kind == "player" then
		return
	end
	if engine_alive(target.unit) and target.unit.key then
		self.target_by_unit[target.unit:key()] = target
	end
	local observations = {}
	local ready = true
	for _, observation in pairs(self.core:observation_records()) do
		if
			observation.target_key == object_key(record.kind, record.id)
			and observation.incarnation == record.incarnation
		then
			observations[#observations + 1] = copy_record(observation)
			ready = ready and self.core:observer(observation.observer_key) ~= nil
		end
	end
	table.sort(observations, function(left, right)
		return left.observer_key < right.observer_key
	end)
	if ready then
		local camera_observations = false
		for _, observation in ipairs(observations) do
			camera_observations = camera_observations or observation.observer_kind == "camera"
		end
		local seed = adapters.camera and adapters.camera.seed_state
		assert(seed or not camera_observations, "ClientsideStealth: camera seed without the SecurityCamera adapter")
		if seed then
			local applied = seed(target.unit, observations)
			ready = applied ~= false and (not camera_observations or applied == true)
		end
	end
	for _, adapter in pairs(adapters) do
		if ready and adapter ~= adapters.camera and adapter.seed_state then
			ready = adapter.seed_state(target.unit, observations) ~= false
		end
	end
	self.seed_failed[object_key(record.kind, record.id)] = not ready and true or nil
end

function Runtime:_on_target_config(record, target)
	local predicted = self.prediction_promoting_target or self:prediction_for_unit(target.unit)
	if predicted and predicted.decision and predicted.decision.config_revision >= record.config_revision then
		return true
	end
	local applied = adapters.world_target.apply_config(target.unit, record) ~= false
	if predicted and predicted.decision then
		return self:update_prediction_attention(target.unit, record) and applied
	end
	return applied
end

function Runtime:register_target(kind, id, unit, details)
	details = details or {}
	local key = object_key(kind, id)
	local previous = self.core:target(key)
	local existed = previous ~= nil
	local previous_config = self.core:target_config(key)
	local previous_owner = self.core:owner_record(key)
	local previous_pending = self.core:pending_handoff(key)
	if previous and previous.unit ~= unit and engine_alive(previous.unit) then
		self.target_by_unit[previous.unit:key()] = nil
	end
	local core_details = copy_record(details)
	if self.core.is_host and details.owner_peer_id ~= nil and details.owner_peer_id ~= self.host_peer_id then
		core_details.owner_peer_id = self.host_peer_id
	end
	local target, error_code = self.core:register_target(kind, id, unit, core_details)

	if target then
		if not existed or details.owner_peer_id ~= nil then
			self.preferred_owners[key] = {
				kind = kind,
				id = id,
				peer_id = details.owner_peer_id or self.host_peer_id,
			}
		end
		if engine_alive(unit) then
			self.target_by_unit[unit:key()] = target
		end
		if
			self.core.is_host
			and details.owner_peer_id ~= nil
			and details.owner_peer_id ~= self.host_peer_id
			and self:can_own(details.owner_peer_id, kind)
		then
			self.core:prepare_owner(
				kind,
				id,
				details.owner_peer_id,
				self.network_time,
				self:_handoff_timeout(details.owner_peer_id)
			)
		end
		if
			self.core.is_host
			and (
				not existed
				or previous.unit ~= target.unit
				or previous.incarnation ~= target.incarnation
				or previous.eligible ~= target.eligible
				or previous_config ~= self.core:target_config(key)
				or previous_owner ~= self.core:owner_record(key)
				or previous_pending ~= self.core:pending_handoff(key)
			)
		then
			self:mark_state_dirty()
		end
		if not self.prediction_promoting then
			self:bind_predicted_unit(kind, id, unit)
		end
		if self.core.is_host then
			self:resolve_native_alerts(unit)
		end
	end

	return target, error_code
end

function Runtime:unregister_target(kind, id)
	local predicted = self.predicted_keys and self.predicted_keys[object_key(kind, id)]
	if predicted then
		return self:cancel_prediction_for_unit(predicted.unit, "removed")
	end
	local key = object_key(kind, id)
	local target = self.core:target(key)
	if target then
		self:cancel_prediction_for_unit(target.unit, "removed")
		self:_forget_native_alert(target)
		self:forget_prediction_proofs(kind, id, target.unit)
	end
	self.prediction_bindings[key] = nil

	if target and engine_alive(target.unit) then
		self.target_by_unit[target.unit:key()] = nil
	end
	self.preferred_owners[key] = nil

	local removed, error_code = self.core:unregister_target(kind, id)
	if removed then
		camera_hud:forget_target(kind, id)
		self:mark_state_dirty()
	end
	return removed, error_code
end

function Runtime:register_observer(kind, id, unit, details)
	local previous = self.core:observer(object_key(kind, id))
	local observer, error_code = self.core:register_observer(kind, id, unit, details)
	if not observer then
		return nil, error_code
	end
	self.observer_details[object_key(kind, id)] = details
	self.observer_unit_keys[object_key(kind, id)] = nil
	if observer and (not previous or previous.unit ~= unit or previous.generation ~= observer.generation) then
		self:mark_state_dirty()
	end
	if observer then
		for _, owner in pairs(self.core:owners()) do
			if owner.owner_peer_id == self.local_peer_id and self.seed_failed[object_key(owner.kind, owner.id)] then
				self:_on_owner(owner)
			end
		end
	end
	return observer, error_code
end

function Runtime:guard_cool_changed(id)
	if self.core.is_host and self.core:observer(object_key("guard", id)) then
		self:mark_state_dirty()
	end
end

function Runtime:restart_observer(kind, id, unit)
	local key = object_key(kind, id)
	local observer = self.core:observer(key)
	if not observer or observer.unit ~= unit then
		return nil, "missing_observer"
	end
	local details = self.observer_details[key]
	self:unregister_observer(kind, id)
	return self:register_observer(kind, id, unit, details)
end

function Runtime:target_identity(kind, id, incarnation)
	local target = self.core:target(object_key(kind, id))
	if not target or incarnation and target.incarnation ~= incarnation or not engine_alive(target.unit) then
		return nil
	end
	return { kind = target.kind, id = target.id, incarnation = target.incarnation, unit = target.unit }
end

function Runtime:target_identity_for_unit(unit)
	local target = self:target_for_unit(unit)
	if not target then
		return nil
	end
	return {
		kind = target.kind,
		id = target.id,
		incarnation = target.incarnation,
		unit = target.unit,
	}
end

function Runtime:target_owner(kind, id)
	local peer_id, epoch = self.core:get_owner(kind, id)
	return peer_id, epoch
end

function Runtime:target_config_for_unit(unit)
	local target = self:target_for_unit(unit)
	return target and self.core:target_config(object_key(target.kind, target.id)), target
end

function Runtime:suspend_target_observations(kind, id, preserve_sequences, clear_observations)
	local owner = self.core:owner_record(object_key(kind, id))
	if not owner then
		return nil, "missing_owner"
	end
	self:_on_cleanup(owner, owner, kind == "bag" and not self.core.is_host)
	if clear_observations == false then
		return true
	end
	local cleared, reason = self.core:clear_target_observations(kind, id, preserve_sequences)
	if cleared then
		self:mark_state_dirty()
	end
	return cleared, reason
end

function Runtime:restore_target_observations(kind, id)
	local owner = self.core:owner_record(object_key(kind, id))
	if owner then
		self:_on_owner(owner)
		return true
	end
	return nil, "missing_owner"
end

function Runtime:prepare_retained_bag(id, peer_id, persistent)
	local key = object_key("bag", id)
	local owner = self.core:owner_record(key)
	if not self.core.is_host or not self.core:target(key) or not owner then
		return nil, "missing_target"
	end
	if not self.core:target_config(key) or not self:is_peer_capable(peer_id) then
		return nil, "ineligible_owner"
	end
	local previous = self.core:pending_handoff(key)
	local retained = persistent and (owner.owner_peer_id == peer_id or previous and previous.owner_peer_id == peer_id)
	local cleared, reason = self:suspend_target_observations("bag", id, persistent)
	if not cleared then
		return nil, reason
	end

	if not self.core:can_own(peer_id, "bag") then
		local current = self.core:assign_owner("bag", id, self.host_peer_id)
		self:mark_state_dirty()
		return { epoch = current.epoch }
	end
	if not retained then
		self.core:assign_owner("bag", id, self.host_peer_id)
	end
	local prepared, error_code = self:assign_owner("bag", id, peer_id, {
		fixed_activation = true,
		persistent = persistent,
	})
	if not prepared then
		local current = self.core:owner_record(key)
		if error_code or not current or current.owner_peer_id ~= peer_id then
			return nil, error_code or "missing_owner"
		end
		prepared = current
	end
	return { handoff = prepared.pending and copy_record(prepared) or nil, epoch = prepared.epoch }
end

function Runtime:send_retained_bag_activation(peer_id, handoff)
	if handoff then
		return self:send_snapshot(peer_id, peer_id, handoff)
	end
	return true
end

function Runtime:authorize_retained_bag_release(handoff)
	return self.core:authorize_handoff_reports(handoff)
end

function Runtime:unregister_observer(kind, id)
	local removed, reason = self.core:unregister_observer(kind, id)
	if removed then
		if kind == "camera" and camera_hud then
			camera_hud:forget_observer(id)
		end
		self.observer_details[object_key(kind, id)] = nil
		self.observer_unit_keys[object_key(kind, id)] = nil
		if kind == "camera" then
			self.pending_camera[id] = nil
		end
	end
	return removed, reason
end

function Runtime:assign_owner(kind, id, peer_id, policy)
	local key = object_key(kind, id)
	local old_owner, old_epoch = self.core:get_owner(kind, id)
	peer_id = peer_id and peer_id > 0 and peer_id or self.host_peer_id
	local record, error_code
	if self.core.is_host and peer_id ~= self.host_peer_id then
		record, error_code =
			self.core:prepare_owner(kind, id, peer_id, self.network_time, self:_handoff_timeout(peer_id), policy)
	else
		record, error_code = self.core:assign_owner(kind, id, peer_id)
	end

	if not record then
		return nil, error_code
	end

	self.preferred_owners[key] = { kind = kind, id = id, peer_id = peer_id }

	if not record.pending and record.owner_peer_id == old_owner and record.epoch == old_epoch then
		return nil, error_code
	end
	self:mark_state_dirty()
	return record
end

function Runtime:target_for_unit(unit)
	if not engine_alive(unit) then
		return nil
	end
	local prediction = self:prediction_for_unit(unit)
	if prediction then
		return prediction.canonical or prediction
	end

	local target = self.target_by_unit[unit:key()]
	if target and target.unit == unit then
		if target.kind ~= "player" then
			return target
		end
		local session = self:session()
		local peer = session and session:local_peer()
		if session and (not peer or peer:id() ~= target.id) then
			peer = session:peer(target.id)
		end
		if not session or peer and peer:unit() == unit then
			return target
		end
	end

	self:sync_players()

	target = self.target_by_unit[unit:key()]
	return target and target.unit == unit and target or nil
end

function Runtime:sync_players()
	if self.syncing_players then
		return
	end

	local session = self:session()

	if not session then
		return
	end

	self.syncing_players = true
	local late_owner
	local function register(peer)
		local unit = peer and peer:unit()

		if engine_alive(unit) then
			local id = peer:id()
			local key = object_key("player", id)
			local target = self.core:target(key)
			local owner = self.core:owner_record(key)
			local pending = self.core:pending_handoff(key)
			local needs_handoff = self.core.is_host
				and id ~= self.local_peer_id
				and self:can_own(id, "player")
				and owner
				and owner.owner_peer_id ~= id
				and not (pending and pending.owner_peer_id == id)
			if
				target
				and target.eligible
				and target.unit == unit
				and owner
				and not self.core:queued_owner(key)
				and not self.core:queued_config(key)
				and not needs_handoff
			then
				return
			end
			local existed = target ~= nil
			self:register_target("player", id, unit, { owner_peer_id = id })
			if self.core.is_host and id ~= self.local_peer_id and not existed and self:can_own(id, "player") then
				late_owner = true
			end
		end
	end

	register(session:local_peer())

	for _, peer in pairs(session:peers()) do
		register(peer)
	end

	self.syncing_players = nil
	if late_owner then
		self:mark_state_dirty()
	end
end

function Runtime:apply_peer_preference(peer_id, enabled, disabled)
	for key, preferred in pairs(enabled and self.preferred_owners or {}) do
		if preferred.peer_id == peer_id and enabled[preferred.kind] and self.core:target(key) then
			self.core:prepare_owner(
				preferred.kind,
				preferred.id,
				peer_id,
				self.network_time,
				self:_handoff_timeout(peer_id)
			)
		end
	end
	for key, owner in pairs(disabled and self.core:owners() or {}) do
		local handoff = self.core:pending_handoff(key)
		if
			disabled[owner.kind] and (owner.owner_peer_id == peer_id or handoff and handoff.owner_peer_id == peer_id)
		then
			local replacement = owner.owner_peer_id == peer_id and self.host_peer_id or owner.owner_peer_id
			self.core:assign_owner(owner.kind, owner.id, replacement)
		end
	end
	self:refresh_snapshot_for_peer(peer_id)
end

function Runtime:owns_local_targets(kinds)
	for _, owner in pairs(self.core:owners()) do
		if owner.owner_peer_id == self.local_peer_id and (not kinds or kinds[owner.kind]) then
			return true
		end
	end
	return false
end

function Runtime:hands_off_from(peer_id, kinds)
	for key, handoff in pairs(self.core:pending_handoffs()) do
		if
			(not kinds or kinds[handoff.kind])
			and self.core:owner_record(key).owner_peer_id == peer_id
			and handoff.owner_peer_id ~= peer_id
		then
			return true
		end
	end
	return false
end

return Runtime
