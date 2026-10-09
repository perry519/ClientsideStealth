local Core, Records, object_key, copy_record = ...
local reject = Records.reject
local valid_integer = Records.valid_integer
local TARGET_KINDS = Records.target_kinds
local OBSERVER_KINDS = Records.observer_kinds
local validate_target_config = Records.validate_target_config

function Core:_reset_registry()
	local previous = self.registry
	self.registry = {
		targets = {},
		observers = {},
		configs = {},
		config_revisions = {},
		incarnations = previous and previous.incarnations or {},
		observer_generations = previous and previous.observer_generations or {},
	}
end

function Core:target(key)
	return self.registry.targets[key]
end

function Core:targets()
	return self.registry.targets
end

function Core:observer(key)
	return self.registry.observers[key]
end

function Core:observers()
	return self.registry.observers
end

function Core:observers_of(kind)
	local list = {}
	for _, observer in pairs(self.registry.observers) do
		if observer.kind == kind then
			list[#list + 1] = observer
		end
	end
	return list
end

function Core:target_config(key)
	return self.registry.configs[key]
end

function Core:target_configs()
	return self.registry.configs
end

function Core:target_config_revision(key)
	return self.registry.config_revisions[key]
end

function Core:incarnation(key)
	return self.registry.incarnations[key]
end

function Core:observer_generation(key)
	return self.registry.observer_generations[key]
end

function Core:_bind_target_incarnation(key, incarnation)
	local registry = self.registry
	registry.targets[key].incarnation = incarnation
	registry.incarnations[key] = math.max(registry.incarnations[key] or 0, incarnation)
end

function Core:_store_target_config(key, record)
	self.registry.configs[key] = copy_record(record)
	self.registry.config_revisions[key] = record.config_revision or 0
end

function Core:_withdraw_target_config(key)
	self.registry.configs[key] = nil
end

function Core:_drop_target_config(key)
	self.registry.configs[key], self.registry.config_revisions[key] = nil, nil
end

function Core:_set_observer_generation(key, generation)
	local registry = self.registry
	registry.observer_generations[key] = math.max(registry.observer_generations[key] or 0, generation)
	local observer = registry.observers[key]
	if observer then
		observer.generation = generation
	end
	return observer ~= nil
end

function Core:register_target(kind, id, unit, details)
	if not TARGET_KINDS[kind] or not valid_integer(id) then
		return reject("invalid_target")
	end
	details = details or {}
	local key = object_key(kind, id)
	local old_target = self.registry.targets[key]
	local incarnation = details.incarnation
	if incarnation == nil and old_target and old_target.unit == unit then
		incarnation = old_target.incarnation
	elseif incarnation == nil and self.is_host then
		incarnation = (self.registry.incarnations[key] or 0) + 1
	elseif incarnation == nil then
		local queued = self:queued_owner(key)
		incarnation = queued and queued.incarnation or 0
	end
	if not valid_integer(incarnation) then
		return reject("invalid_incarnation")
	end
	local validated_config
	if details.config then
		local record = copy_record(details.config)
		record.kind, record.id, record.incarnation = kind, id, incarnation
		local config_error
		validated_config, config_error = validate_target_config(record)
		if not validated_config then
			return nil, config_error
		end
	end
	if old_target and old_target.unit ~= unit then
		self:_retire_owner(key)
		self.registry.configs[key], self.registry.config_revisions[key] = nil, nil
		self:_forget_queued_target(key)
	end
	self.registry.incarnations[key] = math.max(self.registry.incarnations[key] or 0, incarnation)
	self.registry.targets[key] = {
		kind = kind,
		id = id,
		incarnation = incarnation,
		unit = unit,
		eligible = details.eligible ~= false,
	}
	if validated_config then
		self:set_target_config(kind, id, validated_config, incarnation)
	end
	local queued_config = self:queued_config(key)
	if queued_config and queued_config.incarnation == incarnation then
		self:apply_target_config(queued_config)
	end
	local queued = self:queued_owner(key)
	if queued and queued.incarnation == incarnation then
		self:_forget_queued_owner(key)
		self:apply_owner_state(queued)
	elseif not self:owner_record(key) then
		local owner = self:can_own(details.owner_peer_id, kind) and details.owner_peer_id or self.host_peer_id
		self:_set_owner_record(key, {
			kind = kind,
			id = id,
			incarnation = incarnation,
			owner_peer_id = owner,
			epoch = details.epoch or 0,
		})
	end
	return self.registry.targets[key]
end

function Core:set_target_config(kind, id, config, incarnation)
	local key = object_key(kind, id)
	local target = self.registry.targets[key]
	incarnation = incarnation or target and target.incarnation
	local record = copy_record(config or {})
	record.kind, record.id, record.incarnation = kind, id, incarnation
	local validated, error_code = validate_target_config(record)
	if not validated then
		return nil, error_code
	end
	local previous = self.registry.configs[key]
	local changed = previous == nil
	if previous then
		for field, value in pairs(validated) do
			if field ~= "presets" and previous[field] ~= value then
				changed = true
			end
		end
		local a, b = previous.presets or {}, validated.presets or {}
		if #a ~= #b then
			changed = true
		end
		for index, value in ipairs(a) do
			if b[index] ~= value then
				changed = true
			end
		end
	end
	self.registry.configs[key] = validated
	if validated.config_revision ~= nil then
		self.registry.config_revisions[key] = validated.config_revision
	elseif changed then
		self.registry.config_revisions[key] = (self.registry.config_revisions[key] or 0) + 1
	end
	validated.config_revision = self.registry.config_revisions[key] or 0
	return validated
end

function Core:_retire_owner(key)
	local old = self:_drop_owner(key)
	self:_clear_target_runtime(key)
	if old and self.options.on_cleanup then
		self.options.on_cleanup(copy_record(old), nil)
	end
end

function Core:unregister_target(kind, id)
	local key = object_key(kind, id)
	if not self.registry.targets[key] then
		return reject("missing_target")
	end
	local old = self:owner_record(key)
	if old and self.options.on_cleanup then
		self.options.on_cleanup(copy_record(old), nil)
	end
	self:_clear_target_runtime(key)
	self:_drop_owner(key)
	self.registry.targets[key], self.registry.configs[key], self.registry.config_revisions[key] = nil, nil, nil
	self:_forget_queued_target(key)
	return true
end

function Core:register_observer(kind, id, unit, details)
	if not OBSERVER_KINDS[kind] or not valid_integer(id) then
		return reject("invalid_observer")
	end
	details = details or {}
	local key = object_key(kind, id)
	local old = self.registry.observers[key]
	local generation = details.generation or old and old.unit == unit and old.generation or nil
	if generation == nil then
		generation = self.is_host and (self.registry.observer_generations[key] or 0) + 1
			or self:queued_observer_generation(key)
			or 0
	end
	if not valid_integer(generation) then
		return reject("invalid_observer_generation")
	end
	self.registry.observer_generations[key] = math.max(self.registry.observer_generations[key] or 0, generation)
	self:_forget_queued_observer_generation(key)
	self.registry.observers[key] =
		{ kind = kind, id = id, unit = unit, eligible = details.eligible ~= false, generation = generation }
	local queued = kind == "camera" and self:_take_queued_camera(key)
	if queued then
		self:_apply_camera_config(queued)
		self:_apply_camera_enabled(queued)
	end
	return self.registry.observers[key]
end

function Core:unregister_observer(kind, id)
	local key = object_key(kind, id)
	if not self.registry.observers[key] then
		return reject("missing_observer")
	end
	self:_forget_observer(key)
	self.registry.observers[key] = nil
	self:_forget_camera(key, id)
	return true
end

return Core
