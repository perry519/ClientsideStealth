local Validation = {}

function Validation.finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Validation.number(value, minimum, maximum)
	return Validation.finite(value) and value >= minimum and value <= maximum
end

function Validation.integer(value, minimum, maximum)
	return Validation.number(value, minimum, maximum) and value % 1 == 0
end

return Validation
