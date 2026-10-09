local get_runtime, peers = ...
local M = {}

function M.on_intimidated(brain, _amount, aggressor)
	local runtime = get_runtime()
	local unit = brain._unit
	if
		not Network:is_server()
		or not runtime:is_active()
		or not alive(unit)
		or not alive(aggressor)
		or unit:id() < 0
		or managers.enemy:is_civilian(unit)
		or unit:character_damage():dead()
		or brain:surrendered()
		or brain:converted()
	then
		return
	end
	local session = runtime:session()
	local peer = session and session:peer_by_unit(aggressor)
	local peer_id = peer and peer:id()
	if
		not peer_id
		or peer_id == runtime.local_peer_id
		or not runtime:is_peer_capable(peer_id)
		or not peers.allows(peer_id, "intimidation")
	then
		return
	end
	session:send_to_peer_synched(peer, "sync_unit_surrendered", unit, false)
end

return M
