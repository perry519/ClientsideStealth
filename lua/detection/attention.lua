local Runtime, copy_record, engine_alive, adapters, restoring_call, object_key = ...

function Runtime:_identify_attention(attention)
	local unit = attention and attention.unit
	local target = engine_alive(unit) and self.target_by_unit[unit:key()]
	target = target and target.unit == unit and target or nil
	return target and target.kind, target and target.id
end

function Runtime:with_scope(kind, id, callback, ...)
	self.scope_stack[#self.scope_stack + 1] = { kind = kind, id = id, peer_id = self.local_peer_id }
	return restoring_call(function()
		self.scope_stack[#self.scope_stack] = nil
	end, callback, ...)
end

function Runtime:current_scope()
	local scope = self.scope_stack[#self.scope_stack]

	return scope, scope and scope.id
end

function Runtime:delegated_hud_owner(suspect, observer)
	local target = self:target_for_unit(suspect)
	local owner = target and self.core:get_source_owner(target.kind, target.id)
	if not owner or owner == self.host_peer_id then
		return nil
	end
	local id = observer:id()
	local registered = self.core:observer(object_key("guard", id)) or self.core:observer(object_key("camera", id))
	return registered and registered.unit == observer and owner or nil
end

local attention_proxy_methods = {}
local attention_proxy_metatable = {
	__index = function(proxy, name)
		if name == "rel_cache" then
			local cache = {}
			proxy.rel_cache = cache
			return cache
		end
		local method = attention_proxy_methods[name]
		if method then
			return method
		end

		local handler = proxy._cst_handler
		local value = handler[name]
		if type(value) == "function" then
			return function(_, ...)
				return value(handler, ...)
			end
		end

		return value
	end,
}

function attention_proxy_methods:get_attention(...)
	local settings = self._cst_handler:get_attention(...)
	local npc = adapters.npc
	if npc and npc.surrender_attention_settings then
		settings = npc.surrender_attention_settings(self._cst_unit, settings, ...)
	end
	if not settings then
		return nil
	end

	local local_settings = copy_record(settings)
	local notice = settings.notice_clbk
	if self._cst_target and self._cst_target.kind ~= "player" then
		local_settings.notice_clbk = nil
	elseif notice then
		local_settings.notice_clbk = adapters.player.local_notice(self._cst_unit, notice)
	end

	return local_settings
end

function attention_proxy_methods:get_attention_no_cache_query(_, ...)
	return self:get_attention(...)
end

function attention_proxy_methods:get_detection_m_pos(...)
	return self._cst_handler:get_detection_m_pos(...)
end

function attention_proxy_methods:get_ground_m_pos(...)
	return self._cst_handler:get_ground_m_pos(...)
end

function Runtime:_decorate_attention(objects)
	local decorated = {}

	for key, attention in pairs(objects) do
		local copy = copy_record(attention)
		local handler = attention.handler
		local target = self:target_for_unit(attention.unit)
		local proxy = setmetatable({
			_cst_handler = handler,
			_cst_target = target,
			_cst_unit = attention.unit,
		}, attention_proxy_metatable)
		copy.handler = proxy
		decorated[key] = copy
	end

	return decorated
end

function Runtime:is_detection_suppressed(unit)
	return adapters.bag.is_suppressed(unit)
end

function Runtime:filter_attention(objects, keyed_by_unit)
	if not self:is_active() then
		return objects
	end

	local scope = self:current_scope()
	local filtered = self.core:filter_scoped(
		objects,
		self.identify_synced_attention,
		keyed_by_unit and self.target_by_unit or nil,
		scope and scope.peer_id
	)
	local unsuppressed
	local holds = self.core.is_host and self:has_detection_holds()
	if holds or adapters.bag.has_suppressed_targets() then
		for key, attention in pairs(filtered) do
			if self:is_detection_suppressed(attention.unit) or holds and self:is_detection_held(attention.unit) then
				unsuppressed = unsuppressed or copy_record(filtered)
				unsuppressed[key] = nil
			end
		end
	end
	filtered = unsuppressed or filtered
	if not self.core.is_host and scope then
		for _, target in pairs(self.predicted_targets or {}) do
			if engine_alive(target.unit) and not self:is_detection_suppressed(target.unit) then
				if filtered == objects then
					filtered = copy_record(filtered)
				end
				local unit_key = target.unit:key()
				local native = objects[unit_key]
				local attention
				if native and native.unit == target.unit then
					attention = copy_record(native)
				else
					attention = { unit = target.unit }
					if target.kind == "npc" or target.kind == "corpse" or target.kind == "hostage" then
						local movement = target.unit.movement and target.unit:movement()
						attention.nav_tracker = movement and movement.nav_tracker and movement:nav_tracker()
					end
				end
				attention.handler = target.attention
				filtered[unit_key] = attention
			end
		end
	end

	if filtered == objects or self.core.is_host then
		return filtered
	end

	return self:_decorate_attention(filtered)
end

return Runtime
