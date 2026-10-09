local placement, supplies, from_host = ...
local M = {}

local DEPLOYABLE_KINDS = {
	BodyBagsBagBase = "bodybags_bag",
	DoctorBagBase = "doctor_bag",
	FirstAidKitBase = "first_aid_kit",
	GrenadeCrateDeployableBase = "grenade_crate",
}

local function on_send_to_host(session, rpc, first, second, third, fourth, fifth, sixth, seventh, eighth)
	if session ~= managers.network:session() or not session:server_peer() then
		return
	end
	if rpc == "place_ammo_bag" then
		placement:sent("ammo_bag", first, second, false, third, fourth)
	elseif rpc == "place_deployable_bag" and DEPLOYABLE_KINDS[first] then
		placement:sent(DEPLOYABLE_KINDS[first], second, third, false, fourth)
	elseif rpc == "place_trip_mine" then
		placement:sent("trip_mine", first, Rotation(second, math.UP), true, third)
	elseif rpc == "request_place_spy_camera" then
		placement:sent("spy_camera", first, Rotation(second, math.UP), true)
	elseif rpc == "request_place_ecm_jammer" then
		placement:ecm_sent(first, second, third, fourth, fifth, sixth, seventh, eighth)
	end
end

function M:install_supplies()
	if self._supplies_installed then
		return
	end
	self._supplies_installed = true
	local original = ClientNetworkSession.send_to_peers_synched
	ClientNetworkSession.send_to_peers_synched = function(network, rpc, unit, ...)
		if supplies.proxy_send(network, rpc, unit, ...) then
			return
		end
		return original(network, rpc, unit, ...)
	end
end

function M:install_placement()
	if self._placement_installed then
		return
	end
	self._placement_installed = true
	Hooks:PostHook(ClientNetworkSession, "send_to_host", "ClientsideStealthEquipment_send", on_send_to_host)
	Hooks:PostHook(
		UnitNetworkHandler,
		"sync_equipment_setup",
		"ClientsideStealthEquipment_setup",
		function(_, unit, _, peer_id)
			placement:equipment_setup(unit, peer_id)
		end
	)
	Hooks:PostHook(
		UnitNetworkHandler,
		"sync_ammo_bag_setup",
		"ClientsideStealthEquipment_ammo_setup",
		function(_, unit, _, peer_id)
			placement:arrive("ammo_bag", unit, peer_id)
		end
	)
	Hooks:PostHook(
		UnitNetworkHandler,
		"activate_trip_mine",
		"ClientsideStealthEquipment_trip_mine_active",
		function(_, unit)
			placement:trip_mine_activated(unit)
		end
	)
	Hooks:PostHook(
		UnitNetworkHandler,
		"from_server_ecm_jammer_place_result",
		"ClientsideStealthEquipment_ecm_success",
		function(handler, unit, _, _, _, _, _, sender)
			if from_host(handler, sender) then
				placement:host_placed("ecm_jammer", unit)
			end
		end
	)
	Hooks:PostHook(
		UnitNetworkHandler,
		"from_server_ecm_jammer_place_result_failed",
		"ClientsideStealthEquipment_ecm_failure",
		function(handler, sender)
			if from_host(handler, sender) then
				placement:host_place_failed("ecm_jammer")
			end
		end
	)
	Hooks:PostHook(
		UnitNetworkHandler,
		"from_server_spy_camera_place_result",
		"ClientsideStealthEquipment_spy_camera_success",
		function(handler, unit, sender)
			if from_host(handler, sender) then
				placement:host_placed("spy_camera", unit)
			end
		end
	)
	Hooks:PostHook(
		UnitNetworkHandler,
		"from_server_spy_camera_place_result_failed",
		"ClientsideStealthEquipment_spy_camera_failure",
		function(handler, sender)
			if from_host(handler, sender) then
				placement:host_place_failed("spy_camera")
			end
		end
	)
end

return M
