local get_runtime, adapters = ...
local M = {}

function M.peer_id(unit)
	if not unit then
		return nil
	end
	local base = unit.base and unit:base()
	if base and base.thrower_unit then
		unit = base:thrower_unit() or unit
		base = unit.base and unit:base()
	end
	if base and base.get_owner_peer then
		local peer = base:get_owner_peer()
		if peer then
			return peer:id()
		end
	end
	if base and base.get_owner_id then
		local id = base:get_owner_id()
		if id then
			return id
		end
	end
	local session = managers.network and managers.network:session()
	local peer = session and session:peer_by_unit(unit)
	return peer and peer:id() or nil
end

function M.responsible_unit(unit)
	if not unit then
		return nil
	end
	local base = unit.base and unit:base()
	if base and base.thrower_unit then
		unit = base:thrower_unit() or unit
	elseif base and base.sentry_gun and base.get_owner then
		unit = base:get_owner() or unit
	end
	local peer_id = M.peer_id(unit)
	local session = managers.network and managers.network:session()
	local peer = peer_id and session and session.peer and session:peer(peer_id)
	return peer and peer:unit() or unit
end

function M.register(kind, id, unit, peer_id, fallback_preset)
	local config = M.config(unit, fallback_preset)
	if kind == "bag" and not config then
		return nil
	end
	local runtime = get_runtime()
	local target = runtime:register_target(kind, id, unit, { config = config })
	if target and Network:is_server() then
		runtime:assign_owner(kind, id, peer_id)
	end
	return target
end

function M.unregister_unit(unit)
	local runtime = get_runtime()
	local target = runtime:target_for_unit(unit)
	if target then
		adapters.world_target.clear_target(unit)
		return runtime:unregister_target(target.kind, target.id)
	end
end

return M
