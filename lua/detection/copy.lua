local Tables = {}

function Tables.shallow_copy(record)
	local copy = {}
	for key, value in pairs(record) do
		copy[key] = value
	end
	return copy
end

return Tables
