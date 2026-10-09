local Core = ...

function Core:filter_scoped(objects, identify, candidates, peer_id)
	if not peer_id then
		return objects
	end
	if candidates then
		local host_scope = peer_id == self.host_peer_id
		local filtered = not host_scope and {} or objects
		for key in pairs(candidates) do
			local value = objects[key]
			if value ~= nil then
				local kind, id = identify(value, key)
				local keep = kind and id and self:is_owned(kind, id, peer_id) or not kind and host_scope
				if host_scope and not keep then
					if filtered == objects then
						filtered = {}
						for copied_key, copied in pairs(objects) do
							filtered[copied_key] = copied
						end
					end
					filtered[key] = nil
				elseif not host_scope and keep then
					filtered[key] = value
				end
			end
		end
		return filtered
	end
	local filtered = {}
	for key, value in pairs(objects) do
		local kind, id = identify(value, key)
		if kind and id and self:is_owned(kind, id, peer_id) then
			filtered[key] = value
		elseif not kind and peer_id == self.host_peer_id then
			filtered[key] = value
		end
	end
	return filtered
end

return Core
