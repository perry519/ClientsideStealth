local M, get_runtime, adapters = ...
local client_handlers = {}

local function native_handler(unit)
	local attention = unit and unit.attention and unit:attention()
	if attention and attention.attention_data then
		return attention
	end
	local base = unit and unit.base and unit:base()
	local device = base and base._attention_handler
	if device and device.attention_data then
		return device
	end
	local brain = unit and unit.brain and unit:brain()
	local handler = brain and brain.attention_handler and brain:attention_handler()
	return handler and handler.attention_data and handler or nil
end

function M.attention_handler(unit)
	return unit and client_handlers[unit:key()] or native_handler(unit)
end

local function settings_config(settings, presets, team_id)
	return {
		presets = presets,
		team_id = team_id,
		reaction = AIAttentionObject[settings.reaction] or settings.reaction,
		notice_delay_mul = settings.notice_delay_mul,
		verification_interval = settings.verification_interval,
		release_delay = settings.release_delay,
		uncover_range = settings.uncover_range,
		max_range = settings.max_range,
		notice_requires_fov = settings.notice_requires_FOV,
		verification_requires_fov = settings.verification_requires_FOV,
	}
end

function M.config(unit, fallback_preset)
	local attention = M.attention_handler(unit)
	local data = attention and attention.attention_data and attention:attention_data()
	local names = {}
	for name in pairs(data or {}) do
		if type(name) ~= "string" or not tweak_data.attention.settings[name] then
			return nil
		end
		local active = data[name]
		if type(active) ~= "table" then
			return nil
		end
		local descriptor = tweak_data.attention.settings[name]
		local reaction = AIAttentionObject[descriptor.reaction] or descriptor.reaction
		local filter = managers.groupai:state():get_unit_type_filter(descriptor.filter)
		if active.reaction ~= reaction or active.filter ~= filter then
			return nil
		end
		for _, field in ipairs({
			"notice_delay_mul",
			"verification_interval",
			"release_delay",
			"uncover_range",
			"max_range",
			"notice_requires_FOV",
			"verification_requires_FOV",
		}) do
			if active[field] ~= descriptor[field] then
				return nil
			end
		end
		names[#names + 1] = name
	end
	table.sort(names)
	if #names == 0 and fallback_preset then
		names[1] = fallback_preset
	end
	local preset = names[1]
	local fallback = tweak_data and tweak_data.attention and tweak_data.attention.settings[fallback_preset]
	local settings = preset and data and data[preset] or fallback
	if not preset or not settings then
		return nil
	end
	local movement = unit.movement and unit:movement()
	local team = attention and attention._team or movement and movement:team()
	return settings_config(settings, names, settings.team_id or team and team.id)
end

function M.projected_config(unit, presets)
	local config = M.config(unit, presets[1])
	local first = tweak_data.attention.settings[presets[1]]
	if not config or not first then
		return nil
	end
	return settings_config(first, presets, config.team_id)
end

function M.corpse_prediction_config(unit)
	local civilian = CopDamage.is_civilian(unit:base()._tweak_table)
	local presets = civilian and { "civ_enemy_corpse_sneak" }
		or { "enemy_civ_cbt", "enemy_law_corpse_sneak", "enemy_team_corpse_sneak" }
	return M.projected_config(unit, presets)
end

local function preset_settings(presets, team)
	local settings = {}
	for _, preset in ipairs(presets) do
		local descriptor = tweak_data.attention.settings[preset]
		if not descriptor then
			return nil
		end
		local setting = clone(descriptor)
		setting.id = preset
		setting.filter = managers.groupai:state():get_unit_type_filter(setting.filter)
		setting.reaction = AIAttentionObject[setting.reaction] or setting.reaction
		setting.team = team
		setting.notice_clbk = nil
		settings[preset] = setting
	end
	return settings
end

function M.prediction_attention(unit, config)
	if not unit or not config or not config.presets or #config.presets == 0 then
		return nil
	end
	local settings = preset_settings(config.presets)
	if not settings then
		return nil
	end
	local movement = unit.movement and unit:movement()
	local native = native_handler(unit)
	local team = config.team_id and managers.groupai:state():team_data(config.team_id) or movement and movement:team()
	local listeners = {}
	return {
		unit = unit,
		_team = team,
		_cst_listeners = listeners,
		add_listener = function(_, key, callback)
			listeners[key] = callback
		end,
		remove_listener = function(_, key)
			listeners[key] = nil
		end,
		_call_listeners = function()
			for _, listener in pairs(listeners) do
				listener(unit:key())
			end
		end,
		attention_data = function()
			return settings
		end,
		get_attention = function(_, filter, minimum, maximum, observer_team)
			local match
			local relation = observer_team
				and team
				and (observer_team.foes and observer_team.foes[team.id] and "foe" or "friend")
			for _, setting in pairs(settings) do
				if
					(not minimum or minimum <= setting.reaction)
					and (not maximum or setting.reaction <= maximum)
					and (not relation or not setting.relation or relation == setting.relation)
					and managers.navigation:check_access(setting.filter, filter, 0)
					and (not match or match.reaction < setting.reaction)
				then
					match = setting
				end
			end
			return match
		end,
		get_attention_m_pos = function(_, setting)
			return native and native.get_attention_m_pos and native:get_attention_m_pos(setting)
				or movement and movement:m_head_pos()
				or unit:position()
		end,
		get_detection_m_pos = function()
			return native and native.get_detection_m_pos and native:get_detection_m_pos()
				or movement and movement.m_detect_pos and movement:m_detect_pos()
				or unit:position()
		end,
		get_ground_m_pos = function()
			return native and native.get_ground_m_pos and native:get_ground_m_pos()
				or movement and movement.m_pos and movement:m_pos()
				or unit:position()
		end,
	}
end

function M.transfer_listeners(source, destination)
	local listeners = source and source._cst_listeners
	if not listeners or source == destination or listeners == destination._cst_listeners then
		return
	end
	for key, listener in pairs(listeners) do
		destination:add_listener(key, listener)
		listeners[key] = nil
	end
end

local function refresh_attention(unit)
	M.attention_handler(unit):_call_listeners()
end

local function clear_client_handler(unit)
	local key = unit and unit:key()
	local handler = key and client_handlers[key]
	if handler then
		handler:destroy()
		client_handlers[key] = nil
	end
end

local function presets_match(handler, presets)
	local data = handler:attention_data() or {}
	local count = 0
	local expected = {}
	for _, name in ipairs(presets) do
		expected[name] = true
	end
	for name in pairs(data) do
		count = count + 1
		if not expected[name] then
			return false
		end
	end
	return count == #presets
end

local function apply_config(unit, config)
	if Network:is_server() then
		return true
	end
	if adapters.npc and adapters.npc.surrender_attention_config then
		config = adapters.npc.surrender_attention_config(unit, config)
	end
	local key = unit:key()
	local synthetic = client_handlers[key]
	local existing = synthetic or native_handler(unit)
	if existing and not synthetic then
		return presets_match(existing, config.presets or {})
	end
	local movement = unit and unit.movement and unit:movement()
	if not movement or not CharacterAttentionObject then
		return false
	end
	local team = config.team_id and managers.groupai:state():team_data(config.team_id) or movement:team()
	local settings = preset_settings(config.presets or {}, team)
	if not settings then
		clear_client_handler(unit)
		return false
	end
	local handler = synthetic or CharacterAttentionObject:new(unit)
	handler:set_team(team)
	handler:set_settings_set(settings)
	client_handlers[key] = handler
	if not synthetic and handler._registered then
		managers.groupai:state():on_AI_attention_changed(key)
	end
	return true
end
local function report_eligible(observer, target, report)
	local runtime = get_runtime()
	local prediction = runtime.prediction_for_unit and runtime:prediction_for_unit(target)
	local handler = prediction and prediction.attention or client_handlers[target:key()] or native_handler(target)
	if not handler or not handler.get_attention then
		return false
	end
	if report.observer_kind == "camera" then
		local camera = observer:base()
		return camera
			and camera._SO_access
			and handler:get_attention(camera._SO_access, AIAttentionObject.REACT_SUSPICIOUS, nil, camera._team)
				~= nil
	end
	local brain = observer:brain()
	local data = brain and (brain._logic_data or brain._cst_detection_data)
	return data and handler:get_attention(data.SO_access, nil, nil, data.team) ~= nil or false
end
local function clear_session()
	for key, handler in pairs(client_handlers) do
		handler:destroy()
		client_handlers[key] = nil
	end
end

adapters:register("world_target", {
	prediction_attention = M.prediction_attention,
	config = M.config,
	attention_handler = M.attention_handler,
	refresh_attention = refresh_attention,
	apply_config = apply_config,
	report_eligible = report_eligible,
	clear_target = clear_client_handler,
	clear_session = clear_session,
})

function M.remap_entry(entries, old_key, new_key, unit, handler)
	local entry = entries[old_key]
	M.transfer_listeners(entry.handler, handler)
	entry.unit, entry.u_key, entry.handler = unit, new_key, handler
	entry.m_pos = handler:get_ground_m_pos()
	entry.m_head_pos = handler:get_detection_m_pos()
	entries[old_key] = nil
	entries[new_key] = entry
end

return M
