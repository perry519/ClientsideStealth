local rpc, transport = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	for _, descriptor in ipairs(rpc.messages) do
		local name, count = descriptor.name, #descriptor.params
		UnitNetworkHandler[name] = function(handler, ...)
			if select("#", ...) ~= count + 1 then
				return
			end
			local args = { ... }
			local peer = handler._verify_sender(args[count + 1])
			if not peer then
				return
			end
			args[count + 1] = nil
			args.n = count
			return transport:receive_rpc(peer:id(), name, args)
		end
	end
end

return M
