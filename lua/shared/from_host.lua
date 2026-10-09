return function(handler, sender)
	local session = managers.network:session()
	local host = session and session:server_peer()
	if not host or not Network:is_client() or not handler._verify_gamestate(handler._gamestate_filter.any_ingame) then
		return false
	end
	local peer = handler._verify_sender(sender)
	return peer and peer:id() == host:id() or false
end
