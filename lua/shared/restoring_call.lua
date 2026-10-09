local traceback = debug.traceback
local protected_call = _G.blt and _G.blt.xpcall or xpcall

local function with_traceback(message)
	if type(message) ~= "string" or message:find("\nstack traceback:", 1, true) then
		return message
	end
	return traceback(message, 2)
end

local function finish(restore, ok, ...)
	restore()
	assert(ok, (...))
	return ...
end

return function(restore, fn, ...)
	return finish(restore, protected_call(fn, with_traceback, ...))
end
