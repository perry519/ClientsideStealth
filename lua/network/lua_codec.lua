local Records, Schema = ...
local Codec = {}
local MAX_MESSAGE_BYTES = 512
local STATE_FIELD_COUNT = 24
local reject = Records.reject
local valid_integer = Records.valid_integer
local valid_number = Records.valid_number
function Codec.parse_fields(payload, max_bytes)
	if type(payload) ~= "string" or #payload > max_bytes then
		return nil
	end
	local fields = {}
	for value in (payload .. "|"):gmatch("([^|]*)|") do
		fields[#fields + 1] = value
	end
	return fields
end
local function split_fixed(payload, count)
	if type(payload) ~= "string" then
		return reject("invalid_payload")
	end
	if #payload > MAX_MESSAGE_BYTES then
		return reject("oversized")
	end

	local fields = {}
	local start = 1
	for index = 1, count - 1 do
		local separator = string.find(payload, "|", start, true)
		if not separator then
			return reject("field_count")
		end
		fields[index] = string.sub(payload, start, separator - 1)
		start = separator + 1
	end
	if string.find(payload, "|", start, true) then
		return reject("field_count")
	end
	fields[count] = string.sub(payload, start)
	return fields
end

local function join(fields)
	local payload = table.concat(fields, "|")
	if #payload > MAX_MESSAGE_BYTES then
		return reject("oversized")
	end
	return payload
end

local name = {
	encode = tostring,
	decode = function(value)
		return value, true
	end,
}
local integer = {
	encode = tostring,
	decode = function(value)
		local number = tonumber(value)
		return number, valid_integer(number)
	end,
}
local number = {
	encode = function(value)
		return string.format("%.17g", value)
	end,
	decode = function(value)
		local decoded = tonumber(value)
		return decoded, valid_number(decoded)
	end,
}
local boolean = {
	encode = function(value)
		return value and "true" or "false"
	end,
	decode = function(value)
		if value == "true" or value == "false" then
			return value == "true", true
		end
		return nil, false
	end,
}
local function optional(kind)
	return {
		encode = function(value)
			return value == nil and "" or kind.encode(value)
		end,
		decode = function(value)
			if value == "" then
				return nil, true
			end
			return kind.decode(value)
		end,
	}
end
local text = {
	id = integer,
	count = integer,
	optional_id = optional(integer),
	target_kind = name,
	observer_kind = name,
	transition = name,
	key = name,
	token = optional(name),
	boolean = boolean,
	optional_boolean = optional(boolean),
	number = optional(number),
	scalar = optional({
		encode = function(value)
			return type(value) == "boolean" and boolean.encode(value) or number.encode(value)
		end,
		decode = function(value)
			if value == "true" or value == "false" then
				return boolean.decode(value)
			end
			return number.decode(value)
		end,
	}),
	presets = optional({
		encode = function(value)
			return table.concat(value, ",")
		end,
		decode = function(value)
			local presets = {}
			for preset in string.gmatch(value, "[^,]+") do
				presets[#presets + 1] = preset
			end
			return presets, #presets > 0 and table.concat(presets, ",") == value
		end,
	}),
}

local function encode_fields(schema, record, values)
	for _, field in ipairs(schema) do
		values[#values + 1] = text[field[2]].encode(record[field[1]])
	end
	return values
end

local function decode_fields(schema, values, offset, record)
	for index, field in ipairs(schema) do
		local value, valid = text[field[2]].decode(values[offset + index])
		if not valid then
			return nil
		end
		record[field[1]] = value
	end
	return record
end

function Codec.encode_report(record)
	local validated, error_code = Records.validate_report(record)
	if not validated then
		return nil, error_code
	end
	return join(encode_fields(Schema.report, validated, {}))
end

function Codec.decode_report(payload)
	local values, error_code = split_fixed(payload, #Schema.report)
	if not values then
		return nil, error_code
	end
	local record = decode_fields(Schema.report, values, 0, {})
	if not record then
		return reject("invalid_report")
	end
	return record
end

function Codec.encode_state(record)
	local validated, validation_error = Records.validate_state(record)
	if not validated then
		return nil, validation_error
	end
	local values =
		encode_fields(Schema.state[validated.op], validated, { tostring(validated.snapshot_seq), validated.op })
	for index = #values + 1, STATE_FIELD_COUNT do
		values[index] = ""
	end
	return join(values)
end

function Codec.decode_state(payload)
	local values, error_code = split_fixed(payload, STATE_FIELD_COUNT)
	if not values then
		return nil, error_code
	end
	local schema = Schema.state[values[2]]
	if not schema then
		return reject("unknown_enum")
	end
	for index = #schema + 3, STATE_FIELD_COUNT do
		if values[index] ~= "" then
			return reject("invalid_state")
		end
	end
	local record = decode_fields(schema, values, 2, { op = values[2] })
	local snapshot_seq, valid = text.id.decode(values[1])
	if not record or not valid then
		return reject("invalid_state")
	end
	record.snapshot_seq = snapshot_seq
	return record
end

Codec.MAX_MESSAGE_BYTES = MAX_MESSAGE_BYTES

local prediction_fields = {
	{ "op", "token" },
	{ "session_id", "optional_id" },
	{ "membership_id", "optional_id" },
	{ "event_id", "optional_id" },
	{ "parent_id", "optional_id" },
	{ "cause", "token" },
	{ "subject_kind", "token" },
	{ "subject_id", "optional_id" },
	{ "subject_generation", "optional_id" },
	{ "native_token", "token" },
	{ "source_kind", "token" },
	{ "source_id", "optional_id" },
	{ "source_incarnation", "optional_id" },
	{ "source_epoch", "optional_id" },
	{ "observer_kind", "token" },
	{ "observer_id", "optional_id" },
	{ "observer_generation", "optional_id" },
	{ "seq", "optional_id" },
	{ "config_revision", "optional_id" },
	{ "config_signature", "optional_id" },
	{ "transition", "token" },
	{ "value", "scalar" },
	{ "accepted", "optional_boolean" },
	{ "watermark", "optional_id" },
	{ "kind", "token" },
	{ "id", "optional_id" },
	{ "incarnation", "optional_id" },
	{ "epoch", "optional_id" },
	{ "owner_peer_id", "optional_id" },
	{ "reason", "token" },
}
function Codec.encode_prediction(record)
	local validated = Records.validate_prediction(record)
	if not validated then
		return nil
	end
	return join(encode_fields(prediction_fields, validated, {}))
end
function Codec.decode_prediction(payload)
	local values, error_code = split_fixed(payload, #prediction_fields)
	if not values then
		return nil, error_code
	end
	local record = decode_fields(prediction_fields, values, 0, {})
	if not record then
		return reject("invalid_prediction")
	end
	return record
end

local camera_hud_fields = {
	{ "session_id", "id" },
	{ "membership_id", "id" },
	{ "observer_id", "id" },
	{ "observer_generation", "id" },
	{ "target_kind", "target_kind" },
	{ "target_id", "id" },
	{ "incarnation", "id" },
	{ "epoch", "id" },
	{ "seq", "id" },
	{ "active", "boolean" },
}
function Codec.encode_camera_hud(record)
	local validated, error_code = Records.validate_camera_hud(record)
	if not validated then
		return nil, error_code
	end
	return join(encode_fields(camera_hud_fields, validated, {}))
end
function Codec.decode_camera_hud(payload)
	local values, error_code = split_fixed(payload, #camera_hud_fields)
	if not values then
		return nil, error_code
	end
	local record = decode_fields(camera_hud_fields, values, 0, {})
	if not record then
		return reject("invalid_camera_hud")
	end
	return record
end

local peer_envelope = {
	{ "family", "key" },
	{ "session_id", "id" },
	{ "actor", "id" },
	{ "membership", "id" },
	{ "key", "key" },
	{ "version", "id" },
	{ "op", "key" },
}

local peer_receipt = {
	peer_envelope[1],
	peer_envelope[2],
	peer_envelope[3],
	peer_envelope[4],
	peer_envelope[5],
	peer_envelope[6],
	{ "digest", "id" },
	{ "holder", "id" },
}
local peer_families = {}
Codec.PEER_ENVELOPE = peer_envelope

function Codec.define_peer_family(family, fields)
	assert(type(family) == "string" and family:match("^[%w_]+$"), "ClientsideStealth: invalid peer family")
	for _, field in ipairs(fields) do
		assert(text[field[2]], "ClientsideStealth: unknown peer field type " .. tostring(field[2]))
	end
	peer_families[family] = fields
end

local function encode_peer_fields(schema, record, values)
	for _, field in ipairs(schema) do
		local kind = text[field[2]]
		local ok, encoded = pcall(kind.encode, record[field[1]])
		if not ok or type(encoded) ~= "string" or encoded:find("|", 1, true) or not select(2, kind.decode(encoded)) then
			return reject("invalid_peer_field")
		end
		values[#values + 1] = encoded
	end
	return values
end

function Codec.encode_peer(record)
	local fields = type(record) == "table" and peer_families[record.family]
	if not fields then
		return reject("unknown_peer_family")
	end
	local values, error_code = encode_peer_fields(peer_envelope, record, {})
	if values then
		values, error_code = encode_peer_fields(fields, record, values)
	end
	if not values then
		return nil, error_code
	end
	return join(values)
end

function Codec.decode_peer(payload)
	local values = Codec.parse_fields(payload, MAX_MESSAGE_BYTES)
	local fields = values and peer_families[values[1]]
	if not fields then
		return reject(values and "unknown_peer_family" or "invalid_payload")
	end
	if #values ~= #peer_envelope + #fields then
		return reject("field_count")
	end
	local record = decode_fields(peer_envelope, values, 0, {})
	record = record and decode_fields(fields, values, #peer_envelope, record)
	if not record then
		return reject("invalid_peer")
	end
	return record
end

function Codec.encode_peer_receipt(record)
	if type(record) ~= "table" or not peer_families[record.family] then
		return reject("unknown_peer_family")
	end
	local values, error_code = encode_peer_fields(peer_receipt, record, {})
	if not values then
		return nil, error_code
	end
	return join(values)
end

function Codec.decode_peer_receipt(payload)
	local values, error_code = split_fixed(payload, #peer_receipt)
	if not values then
		return nil, error_code
	end
	local record = decode_fields(peer_receipt, values, 0, {})
	if not record or not peer_families[record.family] then
		return reject("invalid_peer_receipt")
	end
	return record
end
return Codec
