local Runtime, Records, State, engine_alive, copy_record = ...
local object_key = State.object_key
local valid_integer = Records.valid_integer
local snapshot_report = { guard = { observer_kind = "guard" }, camera = { observer_kind = "camera" } }
local IDLE_OBSERVER_RESCAN_INTERVAL = 0.1

function Runtime:ownership_snapshot()
	local snapshot = {}
	if not self:is_active() then
		return snapshot
	end
	for key, target in pairs(self.core:targets()) do
		local owner = self.core:owner_record(key)
		if
			owner
			and owner.incarnation == target.incarnation
			and owner.owner_peer_id ~= self.host_peer_id
			and engine_alive(target.unit)
			and not self:is_detection_suppressed(target.unit)
		then
			snapshot[target.unit] = owner.owner_peer_id
		end
	end
	return snapshot
end

function Runtime:camera_suspicion(camera_unit)
	local remote = self:remote_observation_entries()
	local records = self.core:observation_records()
	local first_key, first = next(records)
	local second_key = first and next(records, first_key)
	if
		not remote
		and (
			not first
			or not second_key
				and (first.observer_kind ~= "camera" or first.transition ~= "suspicion" or first.cleared or type(
					first.suspicion_progress
				) ~= "number" or first.suspicion_progress <= 0)
		)
	then
		return nil
	end
	if second_key and not remote then
		local key, observation = first_key, first
		for _ = 1, 8 do
			if not key then
				return nil
			end
			if
				type(observation) ~= "table"
				or observation.transition == "suspicion"
					and not observation.cleared
					and type(observation.suspicion_progress) == "number"
					and observation.suspicion_progress > 0
			then
				break
			end
			key, observation = next(records, key)
		end
		if not key then
			return nil
		end
	end
	local camera_id = engine_alive(camera_unit) and camera_unit:id()
	local observer_key = valid_integer(camera_id) and object_key("camera", camera_id) or nil
	if not observer_key then
		return nil
	end
	local maximum

	for target_key, target in pairs(self.core:targets()) do
		local preview = remote and remote[observer_key .. ">" .. target_key]
		local observation = not preview and self.core:observation(observer_key .. ">" .. target_key)
		local owner = observation and self.core:owner_record(target_key)
		local value = observation and observation.suspicion_progress
		if preview then
			value = not preview.cleared
					and (preview.alarm_pending and 1 or preview.transition == "suspicion" and preview.suspicion_progress)
				or nil
			if
				type(value) == "number"
				and value > 0
				and target.eligible
				and not self:is_detection_suppressed(target.unit)
			then
				maximum = maximum and math.max(maximum, value) or value
			end
		elseif
			observation
			and observation.observer_key == observer_key
			and observation.transition == "suspicion"
			and not observation.cleared
			and target
			and target.eligible
			and engine_alive(target.unit)
			and owner
			and not self:is_detection_suppressed(target.unit)
			and owner.owner_peer_id ~= self.local_peer_id
			and owner.owner_peer_id == observation.owner_peer_id
			and owner.epoch == observation.epoch
			and owner.incarnation == observation.incarnation
			and target.incarnation == observation.incarnation
			and type(value) == "number"
			and value > 0
		then
			maximum = maximum and math.max(maximum, value) or value
		end
	end

	return maximum
end

function Runtime:camera_contribution_targets(camera_unit)
	local contributions = self.remote_camera_suspicion[tostring(camera_unit:key())]
	local targets = {}
	for key in pairs(contributions or {}) do
		local target_key = key:match("^%d+:(.+)$")
		local target = target_key and self.core:target(target_key)
		if target and engine_alive(target.unit) then
			targets[#targets + 1] = target.unit
		end
	end
	return targets
end

function Runtime:camera_detection_entries(camera_unit)
	local contributions = self.remote_camera_suspicion[tostring(camera_unit:key())]
	local entries
	for key, contribution in pairs(contributions or {}) do
		local value = contribution.value
		local sender, target_key = key:match("^(%d+):(.+)$")
		local target = target_key and self.core:target(target_key)
		local owner = target_key and self.core:owner_record(target_key)
		if
			target
			and target.eligible
			and owner
			and owner.owner_peer_id == tonumber(sender)
			and engine_alive(target.unit)
			and type(value) == "number"
			and value > 0
		then
			entries = entries or {}
			local entry = { unit = target.unit }
			entry[contribution.notice and "notice_progress" or "uncover_progress"] = value
			entries[target.unit:key()] = entry
		end
	end
	return entries
end

function Runtime:_on_observation_removed(observation)
	local observer = self.core:observer(observation.observer_key)
	local target = self.core:target(observation.target_key)
	if not observer or not target or not engine_alive(observer.unit) then
		return
	end
	local tombstone = copy_record(observation)
	tombstone.unit = target.unit
	tombstone.observer_unit = observer.unit
	tombstone.target_unit_key = target.unit:key()
	tombstone.observer_unit_key = observer.unit:key()
	tombstone.transition = observation.observer_kind == "guard" and "lost" or "clear"
	tombstone.value = nil
	tombstone.notice_progress = nil
	tombstone.uncover_progress = nil
	tombstone.suspicion_progress = nil
	tombstone.identified = nil
	tombstone.verified = nil
	tombstone.alarmed = nil
	tombstone.cleared = true
	tombstone.expires_at = self.network_time + 1
	self.world_tombstones[observation.observer_key .. ">" .. observation.target_key] = tombstone
end

function Runtime:local_detection_snapshot(output, defer_empty_liveness)
	if not self:is_active() or self.core.is_host then
		return nil
	end
	local player = managers.player and managers.player:player_unit()
	local target = self.core:target(object_key("player", self.local_peer_id))
	if
		not engine_alive(player)
		or not target
		or target.unit ~= player
		or self.core:get_owner("player", self.local_peer_id) ~= self.local_peer_id
	then
		return nil
	end
	local movement = player:movement()
	local state = movement and movement._current_state_name
	local casing = state == "mask_off" or state == "clean" or state == "civilian"
	local player_key = player:key()
	local snapshot = output or {}
	local previous = snapshot.observers
	local now = self.network_time

	local incremental = output
		and defer_empty_liveness
		and type(now) == "number"
		and snapshot._cst_rescan_t
		and now < snapshot._cst_rescan_t
		and snapshot.player == player
		and snapshot.peer_id == self.local_peer_id
	if incremental then
		local attended = snapshot._cst_attended
		for observer_key, previous_key in pairs(attended) do
			local observer = self.core:observer(observer_key)
			local unit_key, record, still_attended
			if observer then
				unit_key, record, still_attended =
					self:_local_observer_record(observer_key, observer, previous, player_key, target, casing, true)
			end
			if unit_key ~= previous_key then
				previous[previous_key] = nil
			end
			if unit_key then
				previous[unit_key] = record
			end
			attended[observer_key] = still_attended and unit_key or nil
		end
		return snapshot
	end
	local observers, attended = {}, {}
	snapshot.player, snapshot.peer_id, snapshot.observers = player, self.local_peer_id, observers
	for observer_key, observer in pairs(self.core:observers()) do
		local unit_key, record, has_attention = self:_local_observer_record(
			observer_key,
			observer,
			previous,
			player_key,
			target,
			casing,
			defer_empty_liveness
		)
		if record then
			observers[unit_key] = record
		end
		if has_attention then
			attended[observer_key] = unit_key
		end
	end
	local reusable = output and defer_empty_liveness and type(now) == "number"
	snapshot._cst_attended = reusable and attended or nil
	snapshot._cst_rescan_t = reusable and now + IDLE_OBSERVER_RESCAN_INTERVAL or nil
	return snapshot
end

function Runtime:_local_observer_record(
	observer_key,
	observer,
	previous,
	player_key,
	target,
	casing,
	defer_empty_liveness
)
	local unit, kind = observer.unit, observer.kind
	local cached_key = self.observer_unit_keys[observer_key]
	local unit_key = cached_key and cached_key.unit == unit and cached_key.key or nil
	local details = self.observer_details[observer_key]
	details = details and details._unit == unit and details or nil
	local deferred_empty
	if defer_empty_liveness and unit_key then
		local cached_data = kind == "guard" and details and details._cst_detection_data
		local cached_entries = cached_data and cached_data.detected_attention_objects
			or kind == "camera" and details and details._detected_attention_objects
		deferred_empty = details
			and (kind == "camera" or cached_data)
			and not (cached_entries and cached_entries[player_key])
	end
	if not deferred_empty and not engine_alive(unit) then
		return unit_key
	end
	local brain = kind == "guard" and (details or unit:brain())
	local data = brain and brain._cst_detection_data
	if kind ~= "camera" and not data then
		return unit_key
	end
	unit_key = unit_key or unit:key()
	if not cached_key or cached_key.unit ~= unit then
		self.observer_unit_keys[observer_key] = { unit = unit, key = unit_key }
	end
	local record = previous and previous[unit_key] or {}
	record.unit, record.kind, record.notice_only = unit, kind, false
	record.notice_progress, record.uncover_progress = nil, nil
	local base = kind == "camera" and (details or unit:base())
	local entries = data and data.detected_attention_objects or base and base._detected_attention_objects
	local attention = entries and entries[player_key]
	if attention and self:_report_eligible(snapshot_report[kind], observer, target) then
		record.notice_progress = type(attention.notice_progress) == "number" and attention.notice_progress or nil
		record.uncover_progress = type(attention.uncover_progress) == "number" and attention.uncover_progress or nil
		if not casing and attention.identified and record.notice_progress == nil and record.uncover_progress == nil then
			record.notice_progress = 1
		end
	end
	return unit_key, record, attention ~= nil
end

function Runtime:world_detection_snapshot()
	if not self:is_active() then
		return nil
	end
	local snapshot = {}
	for _, observation in pairs(self.core:observation_records()) do
		local observer = self.core:observer(observation.observer_key)
		local target = self.core:target(observation.target_key)
		if
			observation.target_kind ~= "player"
			and observer
			and target
			and engine_alive(observer.unit)
			and engine_alive(target.unit)
		then
			local observer_key = observer.unit:key()
			local entry = snapshot[observer_key]
			if not entry then
				entry = { unit = observer.unit, kind = observer.kind, targets = {} }
				snapshot[observer_key] = entry
			end
			local record = copy_record(observation)
			record.unit = target.unit
			if self:is_detection_suppressed(target.unit) then
				record.cleared, record.transition = true, "clear"
				record.notice_progress, record.suspicion_progress, record.uncover_progress = nil, nil, nil
			end
			entry.targets[target.unit:key()] = record
		end
	end
	for key, tombstone in pairs(self.world_tombstones) do
		if tombstone.expires_at <= self.network_time then
			self.world_tombstones[key] = nil
		else
			local entry = snapshot[tombstone.observer_unit_key]
			if not entry then
				entry = { unit = tombstone.observer_unit, kind = tombstone.observer_kind, targets = {} }
				snapshot[tombstone.observer_unit_key] = entry
			end
			entry.targets[tombstone.target_unit_key] = entry.targets[tombstone.target_unit_key]
				or copy_record(tombstone)
		end
	end
	return self:append_prediction_snapshot(self:_overlay_remote(snapshot))
end

function Runtime:_overlay_remote(snapshot)
	for _, entry in pairs(self:remote_observation_entries() or {}) do
		local observer = self.core:observer(entry.observer_key)
		local target = self.core:target(entry.target_key)
		if entry.target_kind ~= "player" and not self:is_detection_suppressed(target.unit) then
			local key = observer.unit:key()
			local slot = snapshot[key]
			if not slot then
				slot = { unit = observer.unit, kind = observer.kind, targets = {} }
				snapshot[key] = slot
			end
			local record = copy_record(entry)
			record.unit = target.unit
			slot.targets[target.unit:key()] = record
		end
	end
	return snapshot
end

return Runtime
