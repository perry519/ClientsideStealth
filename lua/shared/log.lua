local M = {}
local warned = {}

function M.event(event, fields)
	if not (BLTLogs and LogLevel and BLTLogs.log_level == LogLevel.ALL and type(log) == "function") then
		return
	end

	local parts = { "[CST] event=" .. event }
	for index = 1, #fields, 2 do
		parts[#parts + 1] = tostring(fields[index]) .. "=" .. tostring(fields[index + 1])
	end
	log(table.concat(parts, " "))
end

function M.warn_once(...)
	local parts = { "[CST]" }
	for index = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(index, ...))
	end
	local message = table.concat(parts, " ")
	if warned[message] then
		return
	end
	warned[message] = true
	BLT:Log(LogLevel.WARN, message)
end

return M
