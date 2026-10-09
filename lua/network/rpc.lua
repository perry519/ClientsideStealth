local Validation = assert((...), "ClientsideStealth: missing validation dependency")
local Schema = assert(select(2, ...), "ClientsideStealth: missing wire schema")
local PredictionCodec = assert(select(3, ...), "ClientsideStealth: missing prediction codec")
local Channel = Schema.channel
local unpack_values = unpack or table.unpack
local Rpc = {}

Rpc.SCHEMA = "7dc90761"

local ID_MAX = 1000000000
local NUMBER_MAX = 1000000

local function reverse(values)
	local result = {}
	for index, value in ipairs(values) do
		result[value] = index
	end
	return result
end

local function integer(value, minimum, maximum)
	value = tonumber(value)
	if not Validation.integer(value, minimum, maximum) then
		return nil
	end
	return value
end

local function precise(value, limit, optional)
	if optional and (value == nil or value == "") then
		return ""
	end
	value = tonumber(value)
	if not Validation.number(value, -limit, limit) then
		return nil
	end
	return string.format("%.17g", value)
end

local function decode_precise(value, limit, optional)
	if optional and value == "" then
		return nil, true
	end
	local number = tonumber(value)
	if not Validation.number(number, -limit, limit) then
		return nil, false
	end
	return number, true
end

local function optional_boolean(value)
	if value == nil then
		return 0
	elseif value == false then
		return 1
	elseif value == true then
		return 2
	end
	return nil
end

local function decode_optional_boolean(value)
	if value == 0 then
		return nil, true
	elseif value == 1 then
		return false, true
	elseif value == 2 then
		return true, true
	end
	return nil, false
end

local function scalar(value)
	if value == nil then
		return 0, ""
	elseif value == false then
		return 1, ""
	elseif value == true then
		return 2, ""
	end
	local encoded = precise(value, NUMBER_MAX)
	if encoded then
		return 3, encoded
	end
end

local function decode_scalar(tag, value)
	if tag == 0 and value == "" then
		return nil, true
	elseif tag == 1 and value == "" then
		return false, true
	elseif tag == 2 and value == "" then
		return true, true
	elseif tag == 3 then
		return decode_precise(value, NUMBER_MAX)
	end
	return nil, false
end

local function token(value, optional, pattern, maximum)
	if optional and value == nil then
		return ""
	end
	if type(value) ~= "string" or #value > (maximum or 64) or pattern and not value:match(pattern) then
		return nil
	end
	return value
end

local function presets(value)
	if value == nil then
		return ""
	end
	if type(value) ~= "table" or #value == 0 then
		return nil
	end
	local result = {}
	for index, name in ipairs(value) do
		result[index] = token(name, false, "^[%w_%-]+$", 64)
		if not result[index] then
			return nil
		end
	end
	table.sort(result)
	return table.concat(result, ",")
end

local function decode_presets(value)
	if value == "" then
		return nil, true
	end
	local result = {}
	for name in value:gmatch("[^,]+") do
		if not token(name, false, "^[%w_%-]+$", 64) then
			return nil, false
		end
		result[#result + 1] = name
	end
	if #result == 0 or table.concat(result, ",") ~= value then
		return nil, false
	end
	return result, true
end

local function param(type_name, minimum, maximum)
	return { type = type_name, min = minimum, max = maximum }
end

local P_STRING = param("string")

local messages = {}
local by_name = {}
local by_route = {}

local function add(name, channel, op, direction, params, encode, decode)
	local descriptor = {
		name = name,
		channel = channel,
		direction = direction,
		params = params,
		encode = encode,
		decode = decode,
	}
	messages[#messages + 1] = descriptor
	by_name[name] = descriptor
	by_route[channel .. ":" .. (op or "")] = descriptor
end

local function field(params, encode, decode)
	return { params = params, encode = encode, decode = decode }
end

local function int_field(minimum, maximum)
	return field({ param("int", minimum, maximum) }, function(value)
		return integer(value, minimum, maximum)
	end, function(value)
		value = integer(value, minimum, maximum)
		return value, value ~= nil
	end)
end

local function enum_field(names)
	local values = reverse(names)
	return field({ param("int", 1, #names) }, function(value)
		return values[value]
	end, function(value)
		value = names[value]
		return value, value ~= nil
	end)
end

local function precise_field(limit, optional)
	return field({ P_STRING }, function(value)
		return precise(value, limit, optional)
	end, function(value)
		return decode_precise(value, limit, optional)
	end)
end

local function token_field(optional, pattern, maximum)
	return field({ P_STRING }, function(value)
		return token(value, optional, pattern, maximum)
	end, function(value)
		if optional and value == "" then
			return nil, true
		end
		local decoded = token(value, false, pattern, maximum)
		return decoded, decoded ~= nil
	end)
end

local enums = Schema.enums
local types = {
	id = int_field(0, ID_MAX),
	count = int_field(0, 65536),
	target_kind = enum_field(enums.target_kind),
	observer_kind = enum_field(enums.observer_kind),
	transition = enum_field(enums.transition),
	key = token_field(false, "^[%w_:>%-%.]+$", 128),
	token = token_field(true, "^[%w_%-]+$", 64),
	number = precise_field(NUMBER_MAX, true),
	scalar = field({ param("int", 0, 3), P_STRING }, scalar, decode_scalar),
	presets = field({ P_STRING }, presets, decode_presets),
	boolean = field({ param("bool") }, function(value)
		if type(value) == "boolean" then
			return value
		end
	end, function(value)
		return value, type(value) == "boolean"
	end),
	optional_boolean = field({ param("int", 0, 2) }, optional_boolean, decode_optional_boolean),

	optional_id = field({ param("int", -1, ID_MAX) }, function(value)
		return value == nil and -1 or integer(value, 0, ID_MAX)
	end, function(value)
		value = integer(value, -1, ID_MAX)
		if value == -1 then
			return nil, true
		end
		return value, value ~= nil
	end),
}

local function add_record(name, channel, op, direction, entries, wrap_encode, wrap_decode)
	local params = {}
	for _, entry in ipairs(entries) do
		for _, field_param in ipairs(entry[2].params) do
			params[#params + 1] = field_param
		end
	end
	add(name, channel, op, direction, params, function(record)
		if type(record) ~= "table" or wrap_encode and not wrap_encode(record) then
			return nil
		end
		local args = {}
		for _, entry in ipairs(entries) do
			local value = record[entry[1]]
			if not value and entry[3] ~= nil then
				value = entry[3]
			end
			local first, second = entry[2].encode(value)
			if first == nil then
				return nil
			end
			args[#args + 1] = first
			if #entry[2].params == 2 then
				args[#args + 1] = second
			end
		end
		return args
	end, function(args)
		local record, index = {}, 1
		for _, entry in ipairs(entries) do
			local count = #entry[2].params
			local value, valid = entry[2].decode(unpack_values(args, index, index + count - 1))
			if not valid then
				return nil
			end
			record[entry[1]] = value
			index = index + count
		end
		if wrap_decode then
			wrap_decode(record)
		end
		return record
	end)
end

local function schema_entries(schema, entries)
	for _, item in ipairs(schema) do
		entries[#entries + 1] = { item[1], types[item[2]], item[3] }
	end
	return entries
end

local function add_scalar(name, channel, direction, minimum, maximum, decode_string)
	add(name, channel, nil, direction, { param("int", minimum, maximum) }, function(value)
		value = integer(value, minimum, maximum)
		return value and { value } or nil
	end, function(args)
		local value = integer(args[1], minimum, maximum)
		if value == nil then
			return nil
		end
		return decode_string and tostring(value) or value
	end)
end

for _, name in ipairs({ "cst_rpc_v1_ping", "cst_rpc_v1_ack" }) do
	messages[#messages + 1] = {
		name = name,
		params = {
			param("int", 1, 1),
			param("int", 0, ID_MAX),
			param("int", 0, ID_MAX),
			param("int", 0, ID_MAX),
			param("int", 0, ID_MAX),
		},
	}
end
add_scalar("cst_rpc_v1_hello", Channel.hello, "client_to_server", 0, ID_MAX, true)
add_scalar("cst_rpc_v1_ready", Channel.ready, "client_to_server", 0, ID_MAX)
add_record("cst_rpc_v1_report", Channel.report, nil, "client_to_server", schema_entries(Schema.report, {}))

add("cst_rpc_v1_resync", Channel.resync, nil, "client_to_server", {}, function(record)
	if record == "" or record == nil then
		return {}
	end
end, function()
	return ""
end)

local function add_state(op)
	local entries = schema_entries(Schema.state[op], { { "snapshot_seq", types.id } })
	add_record("cst_rpc_v1_state_" .. op, Channel.state, op, "server_to_client", entries, nil, function(record)
		record.op = op
	end)
end
for _, op in ipairs({ "begin", "owner", "target", "observation", "camera", "commit" }) do
	add_state(op)
end

local function array_message(name, channel, op, direction_name, fields)
	local entries = {}
	for index, array_field in ipairs(fields) do
		entries[index] = { index + 1, array_field }
	end
	add_record(name, channel, op, direction_name, entries, function(record)
		return record[1] == op
	end, function(record)
		record[1] = op
	end)
end

local bag_id = types.id
local coordinate = precise_field(NUMBER_MAX)
local rotation = precise_field(3600)
local direction = precise_field(10)
local function secure_token(value)
	value = token(value, false, nil, 64)
	return value and (value:match("^bag:%d+:%d+$") or value:match("^retained:%d+:%d+$")) and value or nil
end
local throw_token = field({ P_STRING }, secure_token, function(value)
	value = secure_token(value)
	return value, value ~= nil
end)

array_message("cst_rpc_v1_bag_secure", Channel.bag, "secure", "client_to_server", {
	throw_token,
	int_field(1, ID_MAX),
	coordinate,
	coordinate,
	coordinate,
	int_field(1, ID_MAX),
	int_field(1, ID_MAX),
})
array_message("cst_rpc_v1_bag_secure_ack", Channel.bag, "secure_ack", "server_to_client", {
	throw_token,
	int_field(0, 1),
	int_field(1, ID_MAX),
	int_field(1, ID_MAX),
})

for _, op in ipairs({ "dropdeny", "release", "held" }) do
	array_message("cst_rpc_v1_bag_" .. op, Channel.bag, op, "server_to_client", { bag_id, bag_id, bag_id, bag_id })
end
array_message("cst_rpc_v1_bag_clear", Channel.bag, "clear", "client_to_server", { bag_id, bag_id, bag_id, bag_id })
array_message("cst_rpc_v1_bag_drop", Channel.bag, "drop", "client_to_server", {
	bag_id,
	bag_id,
	bag_id,
	bag_id,
	token_field(false, "^[%w_]+$", 64),
	coordinate,
	coordinate,
	coordinate,
	rotation,
	rotation,
	rotation,
	direction,
	direction,
	direction,
	int_field(-100, 100),
	token_field(false, "^[%w_:]+$", 64),
})

for _, spec in ipairs({
	{ "identity", "server_to_client" },
	{ "claim", "client_to_server" },
	{ "observe", "client_to_server" },
	{ "decision", "server_to_client" },
	{ "cancel", "client_to_server" },
	{ "ack", "server_to_client" },
	{ "settled", "client_to_server" },
}) do
	local op = spec[1]
	add("cst_rpc_v1_prediction_" .. op, Channel.prediction, op, spec[2], { P_STRING }, function(record)
		local body = PredictionCodec.encode_prediction(record)
		return body and { body } or nil
	end, function(args)
		local record = PredictionCodec.decode_prediction(args[1])
		return record and record.op == op and record or nil
	end)
end

add_state("observer")

add("cst_rpc_v1_camera_hud", Channel.camera_hud, nil, "server_to_client", { P_STRING }, function(record)
	local body = PredictionCodec.encode_camera_hud(record)
	return body and { body } or nil
end, function(args)
	return PredictionCodec.decode_camera_hud(args[1])
end)

add_state("remove")

for _, spec in ipairs({
	{ "peer", Channel.peer, nil, PredictionCodec.encode_peer, PredictionCodec.decode_peer },
	{ "peer_relay", Channel.peer_relay, "server_to_client", PredictionCodec.encode_peer, PredictionCodec.decode_peer },
	{
		"peer_receipt",
		Channel.peer_receipt,
		"client_to_server",
		PredictionCodec.encode_peer_receipt,
		PredictionCodec.decode_peer_receipt,
	},
}) do
	local encode, decode = spec[4], spec[5]
	add("cst_rpc_v1_" .. spec[1], spec[2], nil, spec[3], { P_STRING }, function(record)
		local body = encode(record)
		return body and { body } or nil
	end, function(args)
		return (decode(args[1]))
	end)
end

function Rpc.encode(channel, record)
	local op = type(record) == "table" and (record.op or record[1]) or nil

	local descriptor = by_route[channel .. ":" .. (op or "")] or by_route[channel .. ":"]
	if not descriptor then
		return nil, "unknown_route"
	end
	local args = descriptor.encode(record)
	if not args or #args ~= #descriptor.params then
		return nil, "invalid_record"
	end
	return descriptor.name, args
end

function Rpc.decode(message, args)
	local descriptor = by_name[message]
	if not descriptor then
		return nil, "unknown_message"
	end
	if type(args) ~= "table" or #args ~= #descriptor.params then
		return nil, "invalid_arguments"
	end
	local record = descriptor.decode(args)
	if record == nil then
		return nil, "invalid_arguments"
	end
	return descriptor.channel, record
end

Rpc.messages = messages

return Rpc
