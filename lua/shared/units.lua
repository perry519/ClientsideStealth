local Units = {}

function Units.is_alive(unit)
	return unit ~= nil and (not alive or alive(unit))
end

return Units
