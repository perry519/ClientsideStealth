local session = ...
local M = {}

function M:install_receiver()
	if self._receiver_installed then
		return
	end
	self._receiver_installed = true
	Hooks:Add("NetworkReceivedData", "ClientsideStealthNetwork", session.receive)
	session.announce()
end

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	Hooks:PostHook(BaseNetworkSession, "init", "clientsidestealth_init_session", function(network_session)
		session.init(network_session)
		managers.network:add_event_listener("ClientsideStealthPeerSync", "session_peer_sync_complete", function()
			session.peer_synced()
		end)
	end)
	Hooks:PreHook(BaseNetworkSession, "add_peer", "clientsidestealth_bag_join", function()
		session.peer_added()
	end)
	Hooks:PostHook(BaseNetworkSession, "on_load_complete", "clientsidestealth_level_loaded", function(network_session)
		session.level_loaded(network_session)
	end)
	Hooks:PostHook(BaseNetworkSession, "update", "clientsidestealth_retry_handshake", function()
		session.update(TimerManager:wall():time())
	end)
	Hooks:PostHook(BaseNetworkSession, "remove_peer", "clientsidestealth_remove_peer", function(_, _, peer_id)
		session.peer_lost(peer_id)
	end)
	Hooks:PreHook(BaseNetworkSession, "destroy", "clientsidestealth_destroy_session", function()
		managers.network:remove_event_listener("ClientsideStealthPeerSync")
		session.destroy()
	end)
end

return M
