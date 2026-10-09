local Validation, Schema = ...
assert(Validation and Schema, "ClientsideStealth: missing records dependencies")
local Records = {}
local MAX_INTEGER = 1000000000
local MAX_NUMBER = 1000000
local MAX_STATE_RECORDS = 65536

local function set(list)
	local result = {}
	for _, name in ipairs(list) do
		result[name] = true
	end
	return result
end
local TARGET_KINDS = set(Schema.enums.target_kind)
local OBSERVER_KINDS = set(Schema.enums.observer_kind)
local TRANSITIONS = set(Schema.enums.transition)
local ENUMS = { target_kind = TARGET_KINDS, observer_kind = OBSERVER_KINDS, transition = TRANSITIONS }

local PREDICTION_CAUSES = {
	player_alert = true,
	npc_alert = true,
	bag_drop = true,
	corpse_death = true,
	hostage_tie = true,
	hostage_follow = true,
	hostage_stop = true,
	pager_complete = true,
	vehicle_owner = true,
	prop_attention = true,
}

local function reject(code)
	return nil, code
end

local function valid_integer(value)
	return Validation.integer(value, 0, MAX_INTEGER)
end

local function valid_number(value)
	return Validation.number(value, -MAX_NUMBER, MAX_NUMBER)
end

local TARGET_CONFIG_FIELDS = {
	"reaction",
	"notice_delay_mul",
	"verification_interval",
	"release_delay",
	"uncover_range",
	"max_range",
}

local function valid_identifier(value)
	return type(value) == "string" and #value <= 64 and string.match(value, "^[%w_%-]+$") ~= nil
end

local function valid_optional_number(value)
	return value == nil or valid_number(value)
end

local function valid_optional_boolean(value)
	return value == nil or type(value) == "boolean"
end

local function valid_scalar(value)
	return value == nil or type(value) == "boolean" or valid_number(value)
end

local function valid_token(value)
	return value == nil or value == "" or valid_identifier(value)
end

local function copy_presets(record)
	local source = record.presets
	if source == nil then
		return nil
	end
	if type(source) ~= "table" or #source == 0 then
		return false
	end
	local result = {}
	for index, preset in ipairs(source) do
		if not valid_identifier(preset) then
			return false
		end
		result[index] = preset
	end
	table.sort(result)
	return result
end

function Records.prediction_config_signature(config)
	if type(config) ~= "table" or not valid_token(config.team_id) then
		return nil
	end
	local presets = copy_presets(config)
	if presets == false then
		return nil
	end
	local parts = { table.concat(presets or {}, ","), config.team_id or "" }
	for _, field in ipairs(TARGET_CONFIG_FIELDS) do
		local value = config[field]
		if not valid_optional_number(value) then
			return nil
		end
		parts[#parts + 1] = value == nil and "" or string.format("%.17g", value)
	end
	for _, field in ipairs({ "notice_requires_fov", "verification_requires_fov" }) do
		local value = config[field]
		if not valid_optional_boolean(value) then
			return nil
		end
		parts[#parts + 1] = value == nil and "" or value and "1" or "0"
	end
	local hash = 0
	for _, part in ipairs(parts) do
		for index = 1, #part do
			hash = (hash * 131 + part:byte(index)) % 999999937
		end
		hash = (hash * 131 + 124) % 999999937
	end
	return hash
end

local FIELDS = {
	id = valid_integer,
	count = valid_integer,
	optional_id = function(value)
		return value == nil or valid_integer(value)
	end,
	number = valid_optional_number,
	scalar = valid_scalar,
	boolean = function(value)
		return type(value) == "boolean"
	end,
	optional_boolean = valid_optional_boolean,
	token = valid_token,

	key = function(value)
		return type(value) == "string" and #value <= 128 and value:match("^[%w_:>%-%.]+$") ~= nil
	end,
}

local function copy_fields(fields, record, result, code, enum_code)
	local unknown_enum = false
	for _, field in ipairs(fields) do
		local name, kind, value = field[1], field[2], record[field[1]]
		if not value and field[3] ~= nil then
			value = field[3]
		end
		if ENUMS[kind] then
			unknown_enum = unknown_enum or not ENUMS[kind][value]
		elseif kind == "presets" then
			value = copy_presets(record)
			if value == false then
				return reject(code)
			end
		elseif not FIELDS[kind](value) then
			return reject(code)
		elseif kind == "token" and value == "" then
			value = nil
		end
		result[name] = value
	end
	if unknown_enum then
		return reject(enum_code or code)
	end
	return result
end

local function validate_target_config(record)
	if type(record) ~= "table" then
		return reject("invalid_target_config")
	end
	return copy_fields(Schema.state.target, record, {}, "invalid_target_config")
end

function Records.validate_report(record)
	if type(record) ~= "table" then
		return reject("invalid_report")
	end
	return copy_fields(Schema.report, record, {}, "invalid_report", "unknown_enum")
end

local STATE_REJECTIONS = {
	begin = "invalid_state",
	remove = "invalid_state",
	owner = "invalid_state",
	target = "invalid_target_config",
	observer = "invalid_observer_identity",
	observation = "invalid_observation",
	camera = "invalid_camera",
	commit = "invalid_state",
}

function Records.validate_state(record)
	if type(record) ~= "table" or not valid_integer(record.snapshot_seq) then
		return reject("invalid_state")
	end
	local code = STATE_REJECTIONS[record.op]
	if not code then
		return reject("unknown_enum")
	end
	local result, error_code =
		copy_fields(Schema.state[record.op], record, { snapshot_seq = record.snapshot_seq, op = record.op }, code)
	if not result then
		return nil, error_code
	end
	if
		record.op == "begin"
		and result.owner_count
				+ result.camera_count
				+ result.target_count
				+ result.observation_count
				+ result.observer_count
				+ result.removal_count
			> MAX_STATE_RECORDS
	then
		return reject("invalid_state")
	end

	if record.op == "camera" and not valid_number(result.id) then
		return reject(code)
	end
	return result
end

function Records.object_key(kind, id)
	return kind .. ":" .. tostring(id)
end

Records.reject = reject
Records.valid_integer = valid_integer
Records.valid_number = valid_number
Records.target_kinds = TARGET_KINDS
Records.observer_kinds = OBSERVER_KINDS
Records.validate_target_config = validate_target_config
Records.MAX_STATE_RECORDS = MAX_STATE_RECORDS

function Records.validate_camera_hud(record)
	if type(record) ~= "table" or not TARGET_KINDS[record.target_kind] or type(record.active) ~= "boolean" then
		return reject("invalid_camera_hud")
	end
	local result = { target_kind = record.target_kind, active = record.active }
	for _, name in ipairs({
		"session_id",
		"membership_id",
		"observer_id",
		"observer_generation",
		"target_id",
		"incarnation",
		"epoch",
		"seq",
	}) do
		if not valid_integer(record[name]) then
			return reject("invalid_camera_hud")
		end
		result[name] = record[name]
	end
	if result.session_id == 0 or result.membership_id == 0 or result.observer_generation == 0 then
		return reject("invalid_camera_hud")
	end
	return result
end

function Records.prediction_proof_key(record)
	local cause = record.cause
	if record.subject_kind == "npc" and cause == "player_alert" then
		cause = "npc_alert"
	end
	return record.native_token and (cause .. ":" .. record.native_token)
		or table.concat({ cause, record.subject_kind, record.subject_id, record.subject_generation }, ":")
end

function Records.validate_prediction(record)
	if
		type(record) ~= "table"
		or not valid_integer(record.session_id)
		or not valid_integer(record.membership_id)
		or record.session_id == 0
		or record.membership_id == 0
	then
		return reject("invalid_prediction_identity")
	end
	local result = { op = record.op, session_id = record.session_id, membership_id = record.membership_id }
	if record.op == "identity" then
		return result
	end
	if not valid_integer(record.event_id) or record.event_id == 0 then
		return reject("invalid_prediction_event")
	end
	result.event_id = record.event_id
	if record.op == "claim" then
		if
			not PREDICTION_CAUSES[record.cause]
			or not TARGET_KINDS[record.subject_kind]
			or not valid_integer(record.subject_id)
			or not valid_integer(record.subject_generation)
			or record.parent_id ~= nil and (not valid_integer(record.parent_id) or record.parent_id == 0 or record.parent_id >= record.event_id)
			or record.native_token ~= nil and (type(record.native_token) ~= "string" or #record.native_token > 64 or not record.native_token:match(
				"^[%w_:%-]+$"
			))
			or record.config_signature ~= nil and not valid_integer(record.config_signature)
		then
			return reject("invalid_prediction_claim")
		end
		local has_source = record.source_kind ~= nil
			or record.source_id ~= nil
			or record.source_incarnation ~= nil
			or record.source_epoch ~= nil
		if
			has_source
			and (
				not TARGET_KINDS[record.source_kind]
				or not valid_integer(record.source_id)
				or not valid_integer(record.source_incarnation)
				or not valid_integer(record.source_epoch)
			)
		then
			return reject("invalid_prediction_source")
		end
		if not has_source and not record.parent_id then
			return reject("missing_prediction_source")
		end
		for _, field in ipairs({
			"cause",
			"subject_kind",
			"subject_id",
			"subject_generation",
			"parent_id",
			"native_token",
			"source_kind",
			"source_id",
			"source_incarnation",
			"source_epoch",
			"config_signature",
		}) do
			result[field] = record[field]
		end
	elseif record.op == "observe" then
		if
			not OBSERVER_KINDS[record.observer_kind]
			or not valid_integer(record.observer_id)
			or not valid_integer(record.observer_generation)
			or not valid_integer(record.seq)
			or not valid_integer(record.config_revision)
			or record.config_signature ~= nil and not valid_integer(record.config_signature)
			or not TRANSITIONS[record.transition]
			or not valid_scalar(record.value)
		then
			return reject("invalid_prediction_observation")
		end
		for _, field in ipairs({
			"observer_kind",
			"observer_id",
			"observer_generation",
			"seq",
			"config_revision",
			"config_signature",
			"transition",
			"value",
		}) do
			result[field] = record[field]
		end
	elseif record.op == "decision" then
		if
			type(record.accepted) ~= "boolean"
			or not valid_integer(record.watermark)
			or record.config_signature ~= nil and not valid_integer(record.config_signature)
			or record.accepted and (not TARGET_KINDS[record.kind] or not valid_integer(record.id) or not valid_integer(
				record.incarnation
			) or not valid_integer(record.epoch) or not valid_integer(record.owner_peer_id) or not valid_integer(
				record.config_revision
			))
			or not record.accepted and record.reason ~= nil and not valid_identifier(record.reason)
		then
			return reject("invalid_prediction_decision")
		end
		for _, field in ipairs({
			"accepted",
			"watermark",
			"kind",
			"id",
			"incarnation",
			"epoch",
			"owner_peer_id",
			"config_revision",
			"config_signature",
			"reason",
		}) do
			result[field] = record[field]
		end
	elseif record.op == "ack" then
		if
			not OBSERVER_KINDS[record.observer_kind]
			or not valid_integer(record.observer_id)
			or not valid_integer(record.observer_generation)
			or not valid_integer(record.seq)
			or type(record.accepted) ~= "boolean"
		then
			return reject("invalid_prediction_ack")
		end
		for _, field in ipairs({ "observer_kind", "observer_id", "observer_generation", "seq", "accepted" }) do
			result[field] = record[field]
		end
	elseif record.op == "cancel" then
		if record.reason ~= nil and not valid_identifier(record.reason) then
			return reject("invalid_prediction_cancel")
		end
		result.reason = record.reason
	elseif record.op ~= "settled" then
		return reject("unknown_enum")
	end
	return result
end
return Records
