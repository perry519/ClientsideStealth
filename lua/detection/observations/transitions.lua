local Core, Records, object_key, copy_record = ...
local reject = Records.reject

function Core:_reset_observations()
	self.observations = { records = {}, reports = {}, transitions = {}, camera_alarms = {}, revisions = {} }
end

function Core:observation(key)
	return self.observations.records[key]
end

function Core:observation_records()
	return self.observations.records
end

function Core:detection_advanced(target_key, incarnation)
	for _, observation in pairs(self.observations.records) do
		if
			observation.target_key == target_key
			and observation.incarnation == incarnation
			and (observation.identified or observation.alarmed)
		then
			return true
		end
	end
	return false
end

function Core:observation_revision(target_key)
	return self.observations.revisions[target_key]
end

function Core:_remove_observation(key)
	local observation = self.observations.records[key]
	if observation and self.options.on_observation_removed then
		self.options.on_observation_removed(copy_record(observation))
	end
	self.observations.records[key] = nil
end

function Core:_forget_observer(observer_key)
	local state = self.observations
	for report_key, entry in pairs(state.reports) do
		if entry.observer_key == observer_key then
			state.reports[report_key], state.transitions[report_key], state.camera_alarms[report_key] = nil, nil, nil
		end
	end
	for observation_key, observation in pairs(state.records) do
		if observation.observer_key == observer_key then
			if self.options.on_observation_removed then
				self.options.on_observation_removed(copy_record(observation))
			end
			state.records[observation_key] = nil
			state.revisions[observation.target_key] = (state.revisions[observation.target_key] or 0) + 1
		end
	end
end

local function reject_report(self, peer_id, reason, report)
	if self.options.on_report_rejected then
		self.options.on_report_rejected(peer_id, reason, report and copy_record(report))
	end
	return reject(reason)
end

function Core:_clear_target_runtime(target_key, preserve_sequences)
	for report_key, entry in pairs(self.observations.reports) do
		if entry.target_key == target_key then
			if not preserve_sequences then
				self.observations.reports[report_key] = nil
			end
			self.observations.transitions[report_key], self.observations.camera_alarms[report_key] = nil, nil
		end
	end
	for key, observation in pairs(self.observations.records) do
		if observation.target_key == target_key then
			if self.options.on_observation_removed then
				self.options.on_observation_removed(copy_record(observation))
			end
			if preserve_sequences and not self.is_host and observation.local_detection then
				local cleared = copy_record(observation)
				cleared.transition = observation.observer_kind == "guard" and "lost" or "clear"
				cleared.cleared = true
				cleared.value, cleared.notice_progress, cleared.suspicion_progress, cleared.uncover_progress =
					nil, nil, nil, nil
				cleared.identified, cleared.verified, cleared.alarmed = nil, nil, nil
				self.observations.records[key] = cleared
			else
				self.observations.records[key] = nil
			end
			self.observations.revisions[target_key] = (self.observations.revisions[target_key] or 0) + 1
		end
	end
end

local function report_key(report)
	return object_key(report.observer_kind, report.observer_id)
		.. ">"
		.. object_key(report.target_kind, report.target_id)
		.. "@"
		.. tostring(report.epoch)
		.. "#"
		.. tostring(report.incarnation)
end

local function valid_transition(report, previous, alarmed)
	local transition = report.transition
	if report.observer_kind == "guard" then
		if transition == "notice" then
			return (previous == nil or previous == "lost" or previous == "notice" or previous == "verified")
				and type(report.value) == "number"
				and report.value >= 0
				and report.value <= 1
		elseif transition == "suspicion" then
			return report.target_kind == "player"
				and (previous == "notice" or previous == "verified" or previous == "identified" or previous == "suspicion")
				and type(report.value) == "number"
				and report.value >= 0
				and report.value <= 1
		elseif transition == "verified" then
			return previous == "notice" or previous == "verified" or previous == "identified" or previous == "suspicion"
		elseif transition == "identified" then
			return previous == "notice" or previous == "verified"
		elseif transition == "lost" then
			return previous == "notice" or previous == "verified" or previous == "identified" or previous == "suspicion"
		end
	elseif report.observer_kind == "camera" then
		if transition == "suspicion" or transition == "notice" then
			return not alarmed
				and (previous == nil or previous == "clear" or previous == "suspicion" or previous == "notice")
				and type(report.value) == "number"
				and report.value >= 0
				and report.value <= 1
		elseif transition == "clear" then
			return not alarmed and (previous == "suspicion" or previous == "notice")
		elseif transition == "alarm" then
			return not alarmed
				and (previous == nil or previous == "suspicion" or previous == "notice" or previous == "clear")
		end
	end
	return false
end

function Core:_store_observation(report, observer_key, target_key, local_detection)
	local key = observer_key .. ">" .. target_key
	local previous = self.observations.records[key]
	local observation = previous and copy_record(previous) or {}
	for field, field_value in pairs(report) do
		observation[field] = field_value
	end
	observation.target_key = target_key
	observation.observer_key = observer_key
	observation.local_detection = local_detection == true
	observation.cleared = report.transition == "lost" or report.transition == "clear"
	if report.observer_kind == "guard" then
		if report.transition == "notice" then
			observation.notice_progress = report.value
		elseif report.transition == "suspicion" then
			observation.uncover_progress = report.value
		elseif report.transition == "verified" then
			observation.verified = report.value == 1 or report.value == true
		elseif report.transition == "identified" then
			observation.identified = true
			observation.notice_progress = observation.notice_progress or 1
		elseif report.transition == "lost" then
			observation.notice_progress = nil
			observation.uncover_progress = nil
			observation.identified = nil
			observation.verified = nil
		end
	else
		if report.transition == "suspicion" or report.transition == "notice" then
			observation.suspicion_progress = report.value
		elseif report.transition == "alarm" then
			observation.alarmed = true
			observation.suspicion_progress = observation.suspicion_progress or 1
		elseif report.transition == "clear" then
			observation.suspicion_progress = nil
			observation.alarmed = nil
		end
	end
	self.observations.records[key] = observation

	if
		not previous
		or previous.incarnation ~= observation.incarnation
		or previous.epoch ~= observation.epoch
		or previous.observer_generation ~= observation.observer_generation
		or previous.config_revision ~= observation.config_revision
		or previous.identified ~= observation.identified
		or previous.alarmed ~= observation.alarmed
		or previous.verified ~= observation.verified
		or previous.cleared ~= observation.cleared
	then
		self.observations.revisions[target_key] = (self.observations.revisions[target_key] or 0) + 1
	end
	return observation
end

function Core:receive_report_record(sender_peer_id, record)
	local report, error_code = Records.validate_report(record)
	if not report then
		return reject_report(self, sender_peer_id, error_code)
	end
	if not self.is_host then
		return reject_report(self, sender_peer_id, "not_host", report)
	end
	if not self:_peer_eligible(sender_peer_id) then
		return reject_report(self, sender_peer_id, "ineligible_peer", report)
	end
	if not self:can_own(sender_peer_id, report.target_kind) then
		return reject_report(self, sender_peer_id, "unconfirmed_peer", report)
	end
	local target_key = object_key(report.target_kind, report.target_id)
	local observer_key = object_key(report.observer_kind, report.observer_id)
	local target, observer = self:target(target_key), self:observer(observer_key)
	if not target then
		return reject_report(self, sender_peer_id, "missing_target", report)
	elseif not observer then
		return reject_report(self, sender_peer_id, "missing_observer", report)
	elseif not target.eligible or not observer.eligible then
		return reject_report(self, sender_peer_id, "ineligible", report)
	end
	if report.observer_generation ~= nil and observer.generation ~= report.observer_generation then
		return reject_report(self, sender_peer_id, "stale_observer", report)
	end
	if report.config_revision ~= nil and (self:target_config_revision(target_key) or 0) ~= report.config_revision then
		return reject_report(self, sender_peer_id, "stale_config", report)
	end
	local owner = self:owner_record(target_key)
	local pending = self:pending_handoff(target_key)
	local cutover = pending
		and pending.reports_authorized
		and pending.owner_peer_id == sender_peer_id
		and pending.epoch == report.epoch
		and pending.incarnation == report.incarnation
	if cutover then
		owner = pending
	end
	if not owner or owner.owner_peer_id ~= sender_peer_id then
		return reject_report(self, sender_peer_id, "wrong_owner", report)
	elseif owner.epoch ~= report.epoch then
		return reject_report(self, sender_peer_id, "stale_epoch", report)
	elseif owner.incarnation ~= report.incarnation or target.incarnation ~= report.incarnation then
		return reject_report(self, sender_peer_id, "stale_incarnation", report)
	end
	if self.options.report_eligible then
		local eligible, reason = self.options.report_eligible(report, observer, target)
		if eligible ~= true then
			return reject_report(self, sender_peer_id, reason == "observer_alerted" and reason or "ineligible", report)
		end
	end
	local key = report_key(report)
	local previous_entry = self.observations.reports[key]
	local canonical = self.observations.records[observer_key .. ">" .. target_key]
	if previous_entry and report.seq <= previous_entry.seq then
		return reject_report(self, sender_peer_id, "stale_sequence", report)
	end
	if
		not valid_transition(
			report,
			self.observations.transitions[key] or canonical and canonical.transition,
			self.observations.camera_alarms[key] or canonical and canonical.alarmed
		)
	then
		return reject_report(self, sender_peer_id, "illegal_transition", report)
	end

	if cutover then
		local committed = self:commit_prepared_owner(pending)
		if not committed then
			return reject_report(self, sender_peer_id, "stale_epoch", report)
		end
	end
	local observation_key = observer_key .. ">" .. target_key
	local previous_observation = self.observations.records[observation_key]
	local previous_revision = self.observations.revisions[target_key]
	local previous_transition = self.observations.transitions[key]
	local previous_alarm = self.observations.camera_alarms[key]
	previous_entry = self.observations.reports[key]
	self.observations.reports[key] = {
		seq = report.seq,
		target_key = target_key,
		observer_key = observer_key,
		incarnation = report.incarnation,
	}
	self.observations.transitions[key] = report.transition
	if report.transition == "alarm" then
		self.observations.camera_alarms[key] = true
	end
	report.sender_peer_id = sender_peer_id
	report.owner_peer_id = sender_peer_id
	self:_store_observation(report, observer_key, target_key, false)

	if
		report.observer_kind == "guard"
			and self.options.on_guard_transition
			and self.options.on_guard_transition(copy_record(report), observer, target) == false
		or report.observer_kind == "camera"
			and self.options.on_camera_transition
			and self.options.on_camera_transition(copy_record(report), observer, target) == false
	then
		self.observations.reports[key] = previous_entry
		self.observations.transitions[key] = previous_transition
		self.observations.camera_alarms[key] = previous_alarm
		self.observations.records[observation_key] = previous_observation
		self.observations.revisions[target_key] = previous_revision
		local current = self:owner_record(target_key)
		if
			current
			and current.owner_peer_id == sender_peer_id
			and current.epoch == report.epoch
			and current.incarnation == report.incarnation
		then
			self:assign_owner(report.target_kind, report.target_id, self.host_peer_id)
		end
		return reject_report(self, sender_peer_id, "apply_failed", report)
	end
	if self.options.on_observation then
		self.options.on_observation(copy_record(report), observer, target)
	end
	if self.options.on_report_accepted then
		self.options.on_report_accepted(copy_record(report), sender_peer_id)
	end
	return report
end

function Core:clear_camera_observations(observer_id)
	if not self.is_host then
		return false
	end

	local observer_key = object_key("camera", observer_id)
	local cleared = false
	for _, observation in pairs(self.observations.records) do
		if observation.observer_key == observer_key and not observation.alarmed and not observation.cleared then
			local report = copy_record(observation)
			report.transition, report.value = "clear", 0
			local current = self:_store_observation(report, observer_key, observation.target_key, false)
			local observer = self:observer(observer_key)
			local target = self:target(observation.target_key)
			if self.options.on_observation then
				self.options.on_observation(copy_record(current), observer, target)
			end
			if observer and target and self.options.on_camera_transition then
				self.options.on_camera_transition(copy_record(current), observer, target)
			end
			cleared = true
		end
	end
	return cleared
end

function Core:clear_target_observations(kind, id, preserve_sequences)
	local key = object_key(kind, id)
	if not self:target(key) then
		return reject("missing_target")
	end
	self:_clear_target_runtime(key, preserve_sequences)
	return true
end

function Core:set_local_notice_progress(observer_key, target_key, value)
	local observation = self.observations.records[observer_key .. ">" .. target_key]
	if observation and observation.local_detection and not observation.cleared and not observation.identified then
		observation.notice_progress = value
		return true
	end
	return false
end

function Core:record_local_observation(record)
	local report, reason = Records.validate_report(record)
	if not report then
		return nil, reason
	end
	local target_key = object_key(report.target_kind, report.target_id)
	local observer_key = object_key(report.observer_kind, report.observer_id)
	local target, owner = self:target(target_key), self:owner_record(target_key)
	if not target or not self:observer(observer_key) then
		return reject("missing_target")
	end
	if not owner or owner.owner_peer_id ~= self.local_peer_id then
		return reject("wrong_owner")
	end
	if owner.epoch ~= report.epoch then
		return reject("stale_epoch")
	end
	if owner.incarnation ~= report.incarnation or target.incarnation ~= report.incarnation then
		return reject("stale_incarnation")
	end
	report.owner_peer_id = self.local_peer_id
	return self:_store_observation(report, observer_key, target_key, true)
end

function Core:record_observation(report)
	if type(report) ~= "table" then
		return reject("invalid_report")
	end
	local target_key = object_key(report.target_kind, report.target_id)
	local observer_key = object_key(report.observer_kind, report.observer_id)
	local target, observer, owner = self:target(target_key), self:observer(observer_key), self:owner_record(target_key)
	if not target or not observer or not owner then
		return reject("missing_target")
	end
	report.incarnation = owner.incarnation
	report.epoch = owner.epoch
	report.owner_peer_id = owner.owner_peer_id
	local decoded, error_code = Records.validate_report(report)
	if not decoded then
		return nil, error_code
	end
	decoded.owner_peer_id = owner.owner_peer_id
	decoded.sender_peer_id = owner.owner_peer_id
	local observation =
		self:_store_observation(decoded, observer_key, target_key, owner.owner_peer_id == self.local_peer_id)
	if self.options.on_observation then
		self.options.on_observation(copy_record(observation), observer, target)
	end
	return observation
end

function Core:_apply_observation_state(record, authoritative)
	local target_key = object_key(record.target_kind, record.target_id)
	local observer_key = object_key(record.observer_kind, record.observer_id)
	local target = self:target(target_key)
	local owner = self:owner_record(target_key)
	if target and target.incarnation ~= record.incarnation or owner and owner.incarnation ~= record.incarnation then
		return reject("stale_incarnation")
	end
	local key = observer_key .. ">" .. target_key
	local current = self.observations.records[key]
	if not authoritative and current and current.local_detection and current.incarnation == record.incarnation then
		if current.epoch > record.epoch or current.epoch == record.epoch and current.seq >= record.seq then
			return true
		end
	end
	record.target_key, record.observer_key = target_key, observer_key
	record.cleared = record.transition == "lost" or record.transition == "clear"
	self.observations.records[key] = copy_record(record)
	return true
end

return Core
