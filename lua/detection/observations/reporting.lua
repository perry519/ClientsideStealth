local Runtime, State, engine_alive, log_report, adapters, transport = ...
local object_key = State.object_key

function Runtime:defer_surrender_report(target, report)
	local observer_key = object_key(report.observer_kind, report.observer_id)
	local observer = self.core:observer(observer_key)
	if not observer then
		return
	end
	local owner = self.core:owner_record(object_key(target.kind, target.id))
	target.surrender_reports = target.surrender_reports or {}
	target.surrender_reports[observer_key] = {
		observer_kind = report.observer_kind,
		observer_id = report.observer_id,
		observer_unit = observer.unit,
		observer_generation = observer.generation,
		transition = report.transition,
		value = report.value,
		seq = report.seq,
		incarnation = owner and owner.incarnation,
		epoch = owner and owner.epoch,
		owner_peer_id = owner and owner.owner_peer_id,
	}
end

function Runtime:reconcile_surrender_reports(unit)
	if adapters.npc.surrender_pending(unit) then
		return
	end
	local target = self:target_for_unit(unit)
	local current = target and (target.canonical or target)
	if not current or current.unit ~= unit or not engine_alive(unit) then
		return
	end
	local target_key = object_key(current.kind, current.id)
	local owner = self.core:owner_record(target_key)
	local sources = { [target] = true }
	local predicted = self:prediction_for_unit(unit)
	if predicted then
		sources[predicted] = true
	end
	local latest = {}
	for source in pairs(sources) do
		for observer_key, report in pairs(source.surrender_reports or {}) do
			local previous = latest[observer_key]
			if not previous or report.seq > previous.seq or report.seq == previous.seq and source == current then
				latest[observer_key] = report
			end
		end
		source.surrender_reports = nil
	end
	for observer_key, report in pairs(latest) do
		local observer = self.core:observer(observer_key)
		local local_record = self.core:observation(observer_key .. ">" .. target_key)
		if
			observer
			and observer.unit == report.observer_unit
			and observer.generation == report.observer_generation
			and engine_alive(observer.unit)
			and (not local_record or local_record.seq <= report.seq)
			and (not report.incarnation or owner and owner.incarnation == report.incarnation and owner.epoch == report.epoch and owner.owner_peer_id == report.owner_peer_id)
			and (report.transition == "lost" or report.transition == "clear")
			and (not report.deadline or self.network_time < report.deadline)
		then
			local sent, reason
			if not report.next_retry or self.network_time >= report.next_retry then
				sent, reason = self:send_report(
					observer.kind,
					observer.id,
					current.kind,
					current.id,
					report.transition,
					report.value
				)
			end
			if sent ~= true or reason == "queued" then
				local updated = self.core:observation(observer_key .. ">" .. target_key)
				report.seq = updated and updated.seq or report.seq
				report.deadline = report.deadline or self.network_time + 10
				report.next_retry = report.next_retry and self.network_time < report.next_retry and report.next_retry
					or self.network_time + 1
				current.surrender_reports = current.surrender_reports or {}
				current.surrender_reports[observer_key] = report
			end
		end
	end
end

local function retry_reports(self, targets)
	for _, target in pairs(targets) do
		if target.surrender_reports then
			self:reconcile_surrender_reports(target.unit)
		end
	end
end

function Runtime:retry_surrender_reports()
	retry_reports(self, self.core:targets())
	retry_reports(self, self.predicted_targets)
end

function Runtime:_on_observation()
	self:mark_state_dirty()
end

function Runtime:_report_eligible(report, observer, target)
	if
		not engine_alive(observer.unit)
		or not engine_alive(target.unit)
		or self:is_detection_suppressed(target.unit)
	then
		return false
	end

	local state = managers and managers.groupai and managers.groupai:state()

	if not state or not state:whisper_mode() then
		return false
	end
	if report.observer_kind == "guard" then
		local movement = observer.unit:movement()
		if movement and not movement:cool() then
			return false, "observer_alerted"
		end
	end
	if target.kind ~= "player" and target.kind ~= "vehicle" then
		local adapter = adapters.world_target
		if
			not adapter
			or not adapter.report_eligible
			or adapter.report_eligible(observer.unit, target.unit, report) ~= true
		then
			return false
		end
	end

	if report.observer_kind == "guard" then
		local brain = observer.unit:brain()

		return observer.unit:movement()
			and brain
			and not brain._dead
			and not brain._surrendered
			and not brain._converted
	end

	local camera = observer.unit:base()
	local adapter = adapters.camera

	return camera
		and camera._cst_detection_enabled == true
		and not camera:destroyed()
		and (report.transition == "alarm" or not (adapter and adapter.is_jammed and adapter.is_jammed(camera) or state:is_ecm_jammer_active(
			"camera"
		)))
		and not camera._tape_loop_expired_clbk_id
		and not camera._tape_loop_restarting_t
end

function Runtime:clear_camera_observations(observer_id)
	return self.core:clear_camera_observations(observer_id)
end

function Runtime:_on_cleanup(old, new, preserve_local_alert)
	local record = new or old
	local target = record and self.core:target(object_key(record.kind, record.id))
	local unit = target and target.unit
	if unit and self.prediction_promoting == unit then
		return
	end
	local predicted = unit and self:prediction_for_unit(unit)
	if predicted then
		local decision = predicted.decision

		if
			not decision
			or not new
			or new.incarnation == decision.incarnation
				and (new.owner_peer_id == self.local_peer_id or new.epoch <= decision.epoch)
		then
			return
		end
		self:cancel_prediction_for_unit(unit, "owner_changed")
	end

	if unit and adapters.guard and adapters.guard.cleanup_target then
		adapters.guard.cleanup_target(unit, preserve_local_alert)
	end
	if record.kind == "player" and unit and adapters.player and adapters.player.clear_target then
		adapters.player.clear_target(unit)
	end
	if unit and not new and adapters.world_target and adapters.world_target.clear_target then
		adapters.world_target.clear_target(unit)
	end

	for _, observer in pairs(self.core:observers()) do
		if
			self.core.is_host
			and unit
			and observer.kind == "guard"
			and engine_alive(observer.unit)
			and adapters.guard
			and adapters.guard.cleanup_observer
		then
			adapters.guard.cleanup_observer(observer.unit, unit)
		end
		if observer.kind == "camera" and engine_alive(observer.unit) then
			local adapter = adapters.camera
			if adapter and adapter.cleanup_target then
				adapter.cleanup_target(observer.unit, unit, old)
			end
		end
	end
end

function Runtime:_on_guard(report, observer, target)
	local apply = adapters.guard and adapters.guard.apply_transition
	assert(apply, "ClientsideStealth: guard report without the CopBrain adapter")
	if apply(observer.unit, target.unit, report) == true then
		log_report("report_applied", report, report.sender_peer_id)
		return true
	end
	log_report("report_apply_failed", report, report.sender_peer_id)
	return false
end

function Runtime:_on_camera(report, observer, target)
	local apply = adapters.camera and adapters.camera.apply_report
	assert(apply, "ClientsideStealth: camera report without the SecurityCamera adapter")
	if apply(observer.unit, target.unit, report.transition, report.value, report.sender_peer_id) == true then
		log_report("report_applied", report, report.sender_peer_id)
		return true
	end
	log_report("report_apply_failed", report, report.sender_peer_id)
	return false
end

function Runtime:_on_camera_config(record)
	self.pending_camera[record.id] = record
end

function Runtime:_on_camera_enabled(id)
	local observer = self.core:observer(object_key("camera", id))
	local state = self.pending_camera[id] or self.core:camera_state(id)
	local adapter = adapters.camera

	if observer and state and adapter and adapter.apply_state and adapter.apply_state(observer.unit, state) == true then
		self.pending_camera[id] = nil
		return true
	end
	return false
end

function Runtime:_next_report_seq(observer_kind, observer_id, target_kind, target_id, epoch)
	local key = object_key(observer_kind, observer_id)
		.. ">"
		.. object_key(target_kind, target_id)
		.. "@"
		.. tostring(epoch)
	local next_seq = (self.local_report_seq[key] or 0) + 1

	self.local_report_seq[key] = next_seq

	return next_seq
end

function Runtime:send_report(observer_kind, observer_id, target_kind, target_id, transition, value)
	local predicted = self.predicted_keys and self.predicted_keys[object_key(target_kind, target_id)]
	if predicted then
		return self:send_prediction_report(predicted, observer_kind, observer_id, transition, value)
	end
	local target = self.core:target(object_key(target_kind, target_id))
	if target and self:is_detection_suppressed(target.unit) then
		return nil, "held_target"
	end
	if not self:is_active() then
		return nil, "inactive"
	end

	local peer_id = self.local_peer_id
	local owner, epoch, owner_record = self.core:get_owner(target_kind, target_id)

	if owner ~= peer_id then
		return nil, "wrong_owner"
	end

	local observer = self.core:observer(object_key(observer_kind, observer_id))
	local generation = observer and observer.generation
	local report = {
		epoch = epoch,
		incarnation = owner_record.incarnation,
		observer_id = observer_id,
		observer_kind = observer_kind,
		observer_generation = generation ~= 0 and generation or nil,
		config_revision = self.core:target_config_revision(object_key(target_kind, target_id)),
		seq = self:_next_report_seq(observer_kind, observer_id, target_kind, target_id, epoch),
		target_id = target_id,
		target_kind = target_kind,
		transition = transition,
		value = value,
	}

	if self.core.is_host then
		return self.core:receive_report_record(peer_id, report)
	end
	local stored, store_error = self.core:record_local_observation(report)
	if not stored then
		return nil, store_error
	end
	if target and adapters.npc.surrender_pending(target.unit) then
		self:defer_surrender_report(target, report)
		return true, "queued"
	end

	local queued = not transport:available()
	if not queued then
		local sent, send_error = transport:send(self.host_peer_id, transport.channel.report, report)
		if not sent then
			return false, send_error
		end
		log_report("report_sent", report, peer_id)
	end

	self:propose_remote_observation(stored)

	if target_kind == "player" and target_id == peer_id then
		local player = adapters.player
		if
			target
			and observer
			and player
			and player.apply_detection_report
			and player.apply_detection_report(report, observer, target)
		then
			log_report("local_feedback", report, peer_id)
		end
	end

	return true, queued and "queued" or nil
end

function Runtime:show_local_notice(observer_kind, observer_id, target_kind, target_id, value)
	local observer_key, target_key = object_key(observer_kind, observer_id), object_key(target_kind, target_id)
	local predicted = self.predicted_keys and self.predicted_keys[target_key]
	local feedback = predicted and predicted.feedback and predicted.feedback[observer_key]
	if feedback then
		if not feedback.cleared and not feedback.identified then
			feedback.notice_progress = value
		end
		return true
	end
	local shown = self.core:set_local_notice_progress(observer_key, target_key, value)
	if shown then
		self:propose_remote_progress(observer_key, target_key)
	end
	return shown
end

function Runtime:record_world_observation(observer_kind, observer_id, target_kind, target_id, transition, value)
	if target_kind == "player" and observer_kind ~= "camera" then
		return nil, "not_world_target"
	end
	if not self:is_active() or not self.core.is_host then
		return nil, "not_host"
	end
	local owner, epoch, record = self.core:get_owner(target_kind, target_id)
	if owner ~= self.local_peer_id then
		return nil, "wrong_owner"
	end
	return self.core:record_observation({
		epoch = epoch,
		incarnation = record.incarnation,
		observer_kind = observer_kind,
		observer_id = observer_id,
		target_kind = target_kind,
		target_id = target_id,
		seq = self:_next_report_seq(observer_kind, observer_id, target_kind, target_id, epoch),
		transition = transition,
		value = value,
	})
end

function Runtime:update_camera_state(id, state)
	state.id = id

	return self.core:set_camera_state(state)
end

function Runtime:apply_remote_camera_suspicion(camera_unit, target_key, value, sender, notice)
	local camera_key = engine_alive(camera_unit) and tostring(camera_unit:key()) or nil
	if not camera_key then
		return
	end
	if not target_key then
		self.remote_camera_suspicion[camera_key] = nil
		return
	end
	local contributions = self.remote_camera_suspicion[camera_key] or {}
	self.remote_camera_suspicion[camera_key] = contributions
	contributions[tostring(sender) .. ":" .. target_key] = value ~= nil and { value = value, notice = notice == true }
		or nil
end

return Runtime
