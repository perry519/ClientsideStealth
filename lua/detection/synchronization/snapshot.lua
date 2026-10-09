local Core, Records, object_key, copy_record = ...

function Core:_reset_synchronization()
	self.synchronization = {
		seq = -1,
		committed_sets = {},
		queued_owners = {},
		queued_cameras = {},
		queued_configs = {},
		queued_observer_generations = {},
		camera_states = {},
	}
end

function Core:snapshot_seq()
	return self.synchronization.seq
end

function Core:has_pending_snapshot()
	return self.synchronization.pending ~= nil
end

function Core:camera_state(id)
	return self.synchronization.camera_states[id]
end

function Core:queued_owner(key)
	return self.synchronization.queued_owners[key]
end

function Core:queued_owners()
	return self.synchronization.queued_owners
end

function Core:queued_config(key)
	return self.synchronization.queued_configs[key]
end

function Core:queued_configs()
	return self.synchronization.queued_configs
end

function Core:has_queued_cameras()
	return next(self.synchronization.queued_cameras) ~= nil
end

function Core:queued_observer_generation(key)
	return self.synchronization.queued_observer_generations[key]
end

function Core:_forget_queued_owner(key)
	self.synchronization.queued_owners[key] = nil
end

function Core:_forget_queued_target(key)
	self.synchronization.queued_owners[key], self.synchronization.queued_configs[key] = nil, nil
end

function Core:_forget_queued_observer_generation(key)
	self.synchronization.queued_observer_generations[key] = nil
end

function Core:_take_queued_camera(key)
	local queued = self.synchronization.queued_cameras[key]
	self.synchronization.queued_cameras[key] = nil
	return queued
end

function Core:_forget_camera(key, id)
	self.synchronization.queued_cameras[key], self.synchronization.camera_states[id] = nil, nil
end
local reject = Records.reject
local valid_integer = Records.valid_integer

function Core:raise_snapshot_floor(sequence)
	self.synchronization.floor = math.max(self.synchronization.floor or -1, sequence)
end

function Core:abort_snapshot()
	local aborted = self.synchronization.pending ~= nil or self.synchronization.early ~= nil
	if self.synchronization.pending then
		self:raise_snapshot_floor(self.synchronization.pending.seq)
	end
	if self.synchronization.early then
		self:raise_snapshot_floor(self.synchronization.early.seq)
	end
	self.synchronization.pending = nil
	self.synchronization.early = nil
	return aborted
end

local LISTS = {
	owner = "owner",
	camera = "camera",
	target = "target",
	observer = "observer",
	observation = "observation",
	remove = "removal",
}

local function pending_key(record)
	if record.op == "remove" then
		return record.key
	elseif record.op == "camera" then
		return object_key("camera", record.id)
	elseif record.op == "observation" then
		return object_key(record.observer_kind, record.observer_id)
			.. ">"
			.. object_key(record.target_kind, record.target_id)
	end
	return object_key(record.kind, record.id)
end

local function staging_key(record)
	local key = pending_key(record)
	return record.op == "camera" and key or record.op .. ":" .. key
end

local function clear_lists(pending)
	for _, name in pairs(LISTS) do
		pending[name .. "s"], pending[name .. "_keys"] = {}, {}
	end
end

local function stage(pending, record)
	local name = LISTS[record.op]
	local list, keys, key = pending[name .. "s"], pending[name .. "_keys"], pending_key(record)
	if keys[key] then
		return true
	end
	if #list >= pending[name .. "_count"] then
		return reject("state_count")
	end
	keys[key] = true
	list[#list + 1] = record
	return true
end

local function record_signature(record)
	local names = {}
	for name in pairs(record) do
		if name ~= "snapshot_seq" then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	for index, name in ipairs(names) do
		local value = record[name]
		if type(value) == "number" then
			value = string.format("%.17g", value)
		elseif type(value) == "table" then
			value = table.concat(value, ",")
		end
		names[index] = name .. "=" .. tostring(value)
	end
	return table.concat(names, "|")
end

local function rebuild_delta(self, pending)
	local base = self.synchronization.committed_sets[pending.base_seq]
	if not base then
		return nil
	end
	local merged = {}
	for key, record in pairs(base) do
		merged[key] = copy_record(record)
		merged[key].snapshot_seq = pending.seq
	end
	for _, removal in ipairs(pending.removals) do
		merged[removal.key] = nil
	end
	for op, name in pairs(LISTS) do
		if op ~= "remove" then
			for _, record in ipairs(pending[name .. "s"]) do
				merged[staging_key(record)] = record
			end
		end
	end
	local keys = {}
	for key in pairs(merged) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	clear_lists(pending)
	for _, name in pairs(LISTS) do
		pending[name .. "_count"] = 0
	end
	for _, key in ipairs(keys) do
		local name = LISTS[merged[key].op]
		pending[name .. "_count"] = pending[name .. "_count"] + 1
		stage(pending, merged[key])
	end
	pending.base_seq = 0
	return true
end

function Core:apply_owner_state(record)
	local key = object_key(record.kind, record.id)
	if not self:target(key) then
		self.synchronization.queued_owners[key] = copy_record(record)
		return false, "target_not_ready"
	end
	if self:target(key).incarnation ~= record.incarnation then
		if not self.is_host and self:target(key).incarnation == 0 then
			self:_bind_target_incarnation(key, record.incarnation)
		else
			return reject("stale_incarnation")
		end
	end
	local old = self:owner_record(key)
	local current = {
		kind = record.kind,
		id = record.id,
		incarnation = record.incarnation,
		owner_peer_id = record.owner_peer_id,
		epoch = record.epoch,
		pending_owner_peer_id = record.pending_owner_peer_id,
	}
	self:_set_owner_record(key, current)
	if not old or old.owner_peer_id ~= record.owner_peer_id or old.epoch ~= record.epoch then
		if old and self.options.on_cleanup then
			self.options.on_cleanup(copy_record(old), copy_record(current))
		end
		if self.options.on_owner then
			self.options.on_owner(copy_record(current), old and copy_record(old) or nil)
		end
	end
	return true
end

function Core:apply_target_config(record)
	local key = object_key(record.kind, record.id)
	local target = self:target(key)
	if not target then
		self.synchronization.queued_configs[key] = copy_record(record)
		return false, "target_not_ready"
	end
	if target.incarnation ~= record.incarnation then
		return reject("stale_incarnation")
	end
	if self.options.on_target_config and self.options.on_target_config(copy_record(record), target) == false then
		self:_withdraw_target_config(key)
		self.synchronization.queued_configs[key] = copy_record(record)
		return false, "target_not_ready"
	end
	self:_store_target_config(key, record)
	self.synchronization.queued_configs[key] = nil
	return true
end

function Core:_apply_camera_config(record)
	self.synchronization.camera_states[record.id] = copy_record(record)
	if self.options.on_camera_config then
		self.options.on_camera_config(copy_record(record), self:observer(object_key("camera", record.id)))
	end
end

function Core:_apply_camera_enabled(record)
	if self.options.on_camera_enabled then
		self.options.on_camera_enabled(record.id, record.enabled, self:observer(object_key("camera", record.id)))
	end
end

function Core:_commit_pending_snapshot()
	local pending = self.synchronization.pending

	if
		not pending.committed
		or #pending.owners ~= pending.owner_count
		or #pending.cameras ~= pending.camera_count
		or #pending.targets ~= pending.target_count
		or #pending.observers ~= pending.observer_count
		or #pending.observations ~= pending.observation_count
		or #pending.removals ~= pending.removal_count
	then
		return false
	end
	local is_delta = pending.base_seq > 0
	if is_delta and not rebuild_delta(self, pending) then
		self.synchronization.pending = nil
		if self.options.on_snapshot_base_missing then
			self.options.on_snapshot_base_missing(pending.base_seq)
		end
		return reject("snapshot_base_missing")
	end
	local committed_set = {}
	for op, name in pairs(LISTS) do
		if op ~= "remove" then
			for _, record in ipairs(pending[name .. "s"]) do
				committed_set[staging_key(record)] = copy_record(record)
			end
		end
	end

	local incoming_owners = {}
	for _, owner in ipairs(pending.owners) do
		local key = object_key(owner.kind, owner.id)
		incoming_owners[key] = owner
		local target = self:target(key)
		if target and target.incarnation ~= owner.incarnation and (self.is_host or target.incarnation ~= 0) then
			return reject("stale_incarnation")
		end
		local current = self:owner_record(key)
		if
			current
			and (
				owner.incarnation < current.incarnation
				or owner.incarnation == current.incarnation and owner.epoch < current.epoch
			)
		then
			return reject("stale_epoch")
		end
	end
	for _, config in ipairs(pending.targets) do
		local owner = incoming_owners[object_key(config.kind, config.id)]
		if not owner or owner.incarnation ~= config.incarnation then
			return reject("stale_incarnation")
		end
	end
	for _, observation in ipairs(pending.observations) do
		local key = object_key(observation.target_kind, observation.target_id)
		local owner, current = incoming_owners[key], self:owner_record(key)
		if
			not owner
			or owner.incarnation ~= observation.incarnation
			or current
				and current.incarnation ~= observation.incarnation
				and (self.is_host or current.incarnation ~= 0)
		then
			return reject("stale_incarnation")
		end
	end
	for _, owner in ipairs(pending.owners) do
		local key = object_key(owner.kind, owner.id)
		local target = self:target(key)
		if not self.is_host and target and target.incarnation == 0 then
			self:_bind_target_incarnation(key, owner.incarnation)
			self:_bind_owner_incarnation(key, owner.incarnation)
		end
	end
	for key in pairs(self:owners()) do
		if not pending.owner_keys[key] then
			self:_retire_owner(key)
		end
	end
	for id, old in pairs(self.synchronization.camera_states) do
		if not pending.camera_keys[object_key("camera", id)] then
			if old.enabled and self:observer(object_key("camera", id)) then
				local disabled = copy_record(old)
				disabled.enabled = false
				self:_apply_camera_config(disabled)
				self:_apply_camera_enabled(disabled)
			end
			self.synchronization.camera_states[id] = nil
		end
	end
	for key in pairs(self:target_configs()) do
		if not pending.target_keys[key] then
			self:_drop_target_config(key)
		end
	end
	for key in pairs(self:observers()) do
		if not pending.observer_keys[key] then
			self:_set_observer_generation(key, 0)
		end
	end
	for _, identity in ipairs(pending.observers) do
		local key = object_key(identity.kind, identity.id)
		if not self:_set_observer_generation(key, identity.generation) then
			self.synchronization.queued_observer_generations[key] = identity.generation
		end
	end
	local incoming_config_revisions = {}
	for _, config in ipairs(pending.targets) do
		incoming_config_revisions[object_key(config.kind, config.id)] = config.config_revision or 0
	end
	for key, observation in pairs(self:observation_records()) do
		local owner = incoming_owners[observation.target_key]
		local current_local = observation.local_detection
			and owner
			and observation.owner_peer_id == owner.owner_peer_id
			and observation.epoch == owner.epoch
			and observation.incarnation == owner.incarnation
			and (observation.config_revision == nil or observation.config_revision == incoming_config_revisions[observation.target_key] or observation.target_kind == "npc" and incoming_config_revisions[observation.target_key] ~= nil)
			and (
				observation.observer_generation == nil
				or observation.observer_generation == (self:observer(observation.observer_key) or {}).generation
			)
		if not current_local and (not pending.observation_keys[key] or observation.local_detection) then
			self:_remove_observation(key)
		end
	end
	local previously_queued_configs = self.synchronization.queued_configs
	self.synchronization.queued_owners = {}
	self.synchronization.queued_cameras = {}
	self.synchronization.queued_configs = {}
	local authoritative_targets = {}
	for _, owner in ipairs(pending.owners) do
		if owner.owner_peer_id == self.local_peer_id and owner.pending_owner_peer_id == self.local_peer_id then
			authoritative_targets[object_key(owner.kind, owner.id)] = true
		end
	end
	local previous_set = is_delta and self.synchronization.committed_sets[self.synchronization.seq]
	for _, target in ipairs(pending.targets) do
		local key = object_key(target.kind, target.id)
		local previous = previous_set and previous_set[staging_key(target)]
		local applied = self:target_config(key)
		local signature = previous and applied and record_signature(target)
		if
			not previous
			or not applied
			or previously_queued_configs[key]
			or record_signature(previous) ~= signature
			or record_signature(applied) ~= signature
		then
			local result, reason = self:apply_target_config(target)
			if result == nil then
				return nil, reason
			end
		else
			self:_store_target_config(key, target)
		end
	end
	for _, observation in ipairs(pending.observations) do
		local applied, reason = self:_apply_observation_state(
			observation,
			authoritative_targets[object_key(observation.target_kind, observation.target_id)]
		)
		if applied == nil then
			return nil, reason
		end
	end
	for _, owner in ipairs(pending.owners) do
		local applied, reason = self:apply_owner_state(owner)
		if applied == nil then
			return nil, reason
		end
	end
	for _, camera in ipairs(pending.cameras) do
		local key = object_key("camera", camera.id)
		if self:observer(key) then
			self:_apply_camera_config(camera)
		else
			self.synchronization.queued_cameras[key] = copy_record(camera)
		end
	end
	for _, camera in ipairs(pending.cameras) do
		if self:observer(object_key("camera", camera.id)) then
			self:_apply_camera_enabled(camera)
		end
	end
	self.synchronization.pending = nil
	self.synchronization.seq = pending.seq
	self.synchronization.committed_sets[pending.seq] = committed_set
	local seqs = {}
	for seq in pairs(self.synchronization.committed_sets) do
		seqs[#seqs + 1] = seq
	end
	table.sort(seqs)
	for index = 1, #seqs - 4 do
		self.synchronization.committed_sets[seqs[index]] = nil
	end
	if self.options.on_snapshot_commit then
		self.options.on_snapshot_commit(pending.seq)
	end

	return true
end

function Core:receive_state_record(sender_peer_id, state)
	local record, error_code = Records.validate_state(state)
	if not record then
		return nil, error_code
	end
	if sender_peer_id ~= self.host_peer_id then
		return reject("wrong_host")
	end
	if not self:_peer_eligible(sender_peer_id) then
		return reject("ineligible_peer")
	end
	local early = self.synchronization.early
	if record.op == "begin" then
		if self.synchronization.floor and record.snapshot_seq <= self.synchronization.floor then
			return reject("stale_snapshot")
		end
		if record.snapshot_seq == self.synchronization.seq then
			if self.options.on_snapshot_commit then
				self.options.on_snapshot_commit(record.snapshot_seq)
			end
			return record
		end
		if early and record.snapshot_seq < early.seq then
			return reject("stale_snapshot")
		end
		if self.synchronization.pending and record.snapshot_seq == self.synchronization.pending.seq then
			local committed, reason = self:_commit_pending_snapshot()
			if committed == nil then
				return nil, reason
			end
			return record
		end
		if
			record.snapshot_seq <= self.synchronization.seq
			or self.synchronization.pending and record.snapshot_seq < self.synchronization.pending.seq
		then
			return reject("stale_snapshot")
		end
		self.synchronization.pending = {
			seq = record.snapshot_seq,
			base_seq = record.base_seq,
			owner_count = record.owner_count,
			camera_count = record.camera_count,
			target_count = record.target_count,
			observation_count = record.observation_count,
			observer_count = record.observer_count,
			removal_count = record.removal_count,
		}
		clear_lists(self.synchronization.pending)
		if self.options.on_snapshot_begin then
			self.options.on_snapshot_begin(record.snapshot_seq)
		end
		if early and early.seq == record.snapshot_seq then
			self.synchronization.early = nil
			for _, staged in ipairs(early.records) do
				local applied, reason = self:receive_state_record(sender_peer_id, staged)
				if not applied then
					return nil, reason
				end
			end
			if early.commit then
				local applied, reason = self:receive_state_record(sender_peer_id, early.commit)
				if not applied then
					return nil, reason
				end
			end
		elseif early then
			self.synchronization.early = nil
		end

		return record
	end

	if early and record.snapshot_seq < early.seq then
		return reject("stale_snapshot")
	end
	local pending = self.synchronization.pending
	if not pending or pending.seq ~= record.snapshot_seq then
		if
			self.synchronization.floor and record.snapshot_seq <= self.synchronization.floor
			or record.snapshot_seq <= self.synchronization.seq
			or pending and record.snapshot_seq < pending.seq
			or early and record.snapshot_seq < early.seq
		then
			return reject("stale_snapshot")
		end
		if not early or record.snapshot_seq > early.seq then
			early = { seq = record.snapshot_seq, records = {}, keys = {}, count = 0 }
			self.synchronization.early = early
		end
		if record.op == "commit" then
			early.commit = record
		else
			local key = staging_key(record)
			if not early.keys[key] then
				if early.count >= Records.MAX_STATE_RECORDS then
					return reject("state_count")
				end
				early.keys[key] = true
				early.count = early.count + 1
				early.records[#early.records + 1] = record
			end
		end
		return record
	end
	if record.op == "commit" then
		pending.committed = true
	else
		local staged, reason = stage(pending, record)
		if not staged then
			return nil, reason
		end
	end

	local committed, commit_error = self:_commit_pending_snapshot()

	if committed == nil then
		return nil, commit_error
	end

	return record
end

function Core:set_camera_state(record)
	local state = copy_record(record)
	state.snapshot_seq, state.op = 0, "camera"
	local decoded, decode_error = Records.validate_state(state)
	if not decoded then
		return nil, decode_error
	end
	decoded.snapshot_seq, decoded.op = nil, nil
	self.synchronization.camera_states[record.id] = decoded
	return decoded
end

function Core:snapshot_records(snapshot_seq, activate_peer_id, include_observation)
	if not valid_integer(snapshot_seq) then
		return reject("invalid_state")
	end
	local owner_keys = {}
	for key in pairs(self:owners()) do
		owner_keys[#owner_keys + 1] = key
	end
	table.sort(owner_keys)
	local camera_ids = {}
	for id in pairs(self.synchronization.camera_states) do
		camera_ids[#camera_ids + 1] = id
	end
	table.sort(camera_ids)
	local target_keys = {}
	for key in pairs(self:target_configs()) do
		target_keys[#target_keys + 1] = key
	end
	table.sort(target_keys)
	local observation_keys = {}
	for key, observation in pairs(self:observation_records()) do
		if not include_observation or include_observation(observation) then
			observation_keys[#observation_keys + 1] = key
		end
	end
	table.sort(observation_keys)
	local observer_keys = {}
	for key in pairs(self:observers()) do
		observer_keys[#observer_keys + 1] = key
	end
	table.sort(observer_keys)
	local begin, error_code = Records.validate_state({
		snapshot_seq = snapshot_seq,
		op = "begin",
		owner_count = #owner_keys,
		camera_count = #camera_ids,
		target_count = #target_keys,
		observation_count = #observation_keys,
		observer_count = #observer_keys,
	})
	if not begin then
		return nil, error_code
	end
	local records = { begin }
	for _, key in ipairs(observer_keys) do
		local observer = self:observer(key)
		records[#records + 1] = assert(Records.validate_state({
			snapshot_seq = snapshot_seq,
			op = "observer",
			kind = observer.kind,
			id = observer.id,
			generation = observer.generation,
		}))
	end
	for _, key in ipairs(owner_keys) do
		local owner = self:owner_record(key)
		local state = copy_record(owner)
		local pending = self:pending_handoff(key)
		state.pending_owner_peer_id = pending and pending.owner_peer_id or nil
		if pending and pending.owner_peer_id == activate_peer_id then
			state.owner_peer_id = pending.owner_peer_id
			state.epoch = pending.epoch
		end
		state.snapshot_seq, state.op = snapshot_seq, "owner"
		records[#records + 1] = assert(Records.validate_state(state))
	end
	for _, key in ipairs(target_keys) do
		local state = copy_record(self:target_config(key))
		state.snapshot_seq, state.op = snapshot_seq, "target"
		records[#records + 1] = assert(Records.validate_state(state))
	end
	for _, key in ipairs(observation_keys) do
		local observation = self:observation(key)
		local state = copy_record(observation)
		local pending = self:pending_handoff(observation.target_key)
		if pending and pending.owner_peer_id == activate_peer_id then
			state.epoch = pending.epoch
		end
		state.snapshot_seq, state.op = snapshot_seq, "observation"
		records[#records + 1] = assert(Records.validate_state(state))
	end
	for _, id in ipairs(camera_ids) do
		local state = copy_record(self.synchronization.camera_states[id])
		state.snapshot_seq, state.op = snapshot_seq, "camera"
		records[#records + 1] = assert(Records.validate_state(state))
	end
	records[#records + 1] = assert(Records.validate_state({ snapshot_seq = snapshot_seq, op = "commit" }))
	return records
end

function Core:snapshot_delta(records, base)
	local set = {}
	for index = 2, #records - 1 do
		set[staging_key(records[index])] = record_signature(records[index])
	end
	if not base then
		return records, set
	end
	local begin = copy_record(records[1])
	begin.base_seq = base.seq
	for op, name in pairs(LISTS) do
		if op ~= "remove" then
			begin[name .. "_count"] = 0
		end
	end
	local delta = { begin }
	for index = 2, #records - 1 do
		local record = records[index]
		local key = staging_key(record)
		if base.set[key] ~= set[key] then
			begin[record.op .. "_count"] = begin[record.op .. "_count"] + 1
			delta[#delta + 1] = record
		end
	end
	local removed = {}
	for key in pairs(base.set) do
		if not set[key] then
			removed[#removed + 1] = key
		end
	end
	table.sort(removed)
	for _, key in ipairs(removed) do
		delta[#delta + 1] =
			assert(Records.validate_state({ snapshot_seq = begin.snapshot_seq, op = "remove", key = key }))
	end
	begin.removal_count = #removed
	delta[1] = assert(Records.validate_state(begin))
	delta[#delta + 1] = records[#records]
	return delta, set
end

return Core
