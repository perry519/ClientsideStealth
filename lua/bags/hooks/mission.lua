local retained = ...
local M = {}

function M:install()
	if self._installed then
		return
	end

	local finders =
		assert(ElementAreaTrigger.instigator_find_functions, "ClientsideStealth: area trigger finders missing")

	for _, kind in ipairs({ "loot", "unique_loot" }) do
		local original = assert(finders[kind], "ClientsideStealth: area trigger finder missing: " .. kind)

		finders[kind] = function(values, instigators)
			original(values, instigators)

			for i = #instigators, 1, -1 do
				if retained.is_suppressed(instigators[i]) then
					table.remove(instigators, i)
				end
			end
		end
	end

	local carry_executed = assert(ElementCarry.on_executed, "ClientsideStealth: carry element missing")
	function ElementCarry:on_executed(instigator, ...)
		if Network:is_server() and retained.holding(instigator) then
			return
		end
		return carry_executed(self, instigator, ...)
	end

	self._installed = true
end

return M
