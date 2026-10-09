local world_target = ...
local M = {}

local function owner_peer_id(base)
	local peer = base._cst_owner_peer
	local session = peer and managers.network:session()
	return session and session:peer(peer:id()) == peer and peer:id() or nil
end

function M.set_owner(base, peer_id)
	local session = peer_id and managers.network:session()
	local peer = session and session:peer(peer_id)
	if peer then
		base._cst_owner_peer = peer
	end
end

function M.sync(base)
	local unit = base._unit
	local id = alive(unit) and unit:id()
	if not id or id == -1 then
		return
	end
	local handler = base._attention_handler
	if handler and handler:attention_data() and world_target.config(unit) then
		world_target.register("drill", id, unit, owner_peer_id(base))
	else
		world_target.unregister_unit(unit)
	end
end

function M.placed_by(base, player)
	M.set_owner(base, world_target.peer_id(player))
end

function M.removed(base)
	world_target.unregister_unit(base._unit)
end

return M
