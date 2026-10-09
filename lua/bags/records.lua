local Validation = assert((...), "ClientsideStealth: missing validation dependency")
local M = {}

function M.finite(value, limit, integer)
	return (integer and Validation.integer or Validation.number)(value, -limit, limit)
end

function M.numeric(fields, first, last, limit, integers)
	local values = {}
	for index = first, last do
		local value = tonumber(fields[index])
		if not M.finite(value, limit, integers) then
			return nil
		end
		values[#values + 1] = value
	end
	return values
end

function M.drop_values(fields)
	return M.numeric(fields, 7, 9, 1000000, false),
		M.numeric(fields, 10, 12, 3600, false),
		M.numeric(fields, 13, 15, 10, false),
		M.numeric(fields, 16, 16, 100, true)
end

function M.throw_token(token, peer)
	if type(token) ~= "string" or #token > 64 then
		return false
	end
	local kind, holder, ordinal = token:match("^(%a+):(%d+):(%d+)$")
	return (kind == "bag" or kind == "retained") and tonumber(holder) == peer and tonumber(ordinal) > 0
end

local function token_valid(token)
	local holder = type(token) == "string" and token:match("^%a+:(%d+):%d+$")
	return holder and M.throw_token(token, tonumber(holder))
end

local function authority(fields, first)
	local session, membership = tonumber(fields[first]), tonumber(fields[first + 1])
	if not Validation.integer(session, 1, 1000000000) or not Validation.integer(membership, 1, 1000000000) then
		return nil
	end
	return session, membership
end

function M.secure(fields)
	if type(fields) ~= "table" or #fields ~= 8 or fields[1] ~= "secure" or not token_valid(fields[2]) then
		return nil
	end
	local area = tonumber(fields[3])
	local position = M.numeric(fields, 4, 6, 1000000, false)
	local session, membership = authority(fields, 7)
	if not Validation.integer(area, 1, 1000000000) or not position or not session then
		return nil
	end
	return fields[2], area, position, session, membership
end

function M.secure_ack(fields)
	if type(fields) ~= "table" or #fields ~= 5 or fields[1] ~= "secure_ack" or not token_valid(fields[2]) then
		return nil
	end
	local status = tonumber(fields[3])
	local session, membership = authority(fields, 4)
	if (status ~= 0 and status ~= 1) or not session then
		return nil
	end
	return fields[2], status, session, membership
end

return M
