local CST = dofile(ModPath .. "lua/core.lua") or assert(rawget(_G, "ClientsideStealth"))
local deployables = CST.module("equipment/hooks/deployables")

local installers = {
	["lib/units/beings/player/playerequipment"] = function()
		CST.module("equipment/hooks/player"):install()
	end,
	["lib/network/handlers/unitnetworkhandler"] = function()
		local network = CST.module("equipment/hooks/network")
		network:install_placement()
		network:install_supplies()
		deployables:install_trip_mine_sound()
	end,
	["lib/units/equipment/ecm_jammer/ecmjammerbase"] = function()
		deployables:install_ecm()
	end,
	["lib/units/equipment/bodybags_bag/bodybagsbagbase"] = function()
		deployables:install_bag_sound(BodyBagsBagBase, "bodybags_bag")
	end,
	["lib/units/equipment/ammo_bag/ammobagbase"] = function()
		deployables:install_bag_sound(AmmoBagBase, "ammo_bag")
	end,
	["lib/units/equipment/doctor_bag/doctorbagbase"] = function()
		deployables:install_bag_sound(DoctorBagBase, "doctor_bag")
	end,
	["lib/units/equipment/first_aid_kit/firstaidkitbase"] = function()
		deployables:install_bag_sound(FirstAidKitBase, "first_aid_kit")
	end,
	["lib/units/equipment/grenade_crate/grenadecratebase"] = function()
		deployables:install_grenade()
		deployables:install_bag_sound(GrenadeCrateDeployableBase, "grenade_crate")
	end,
	["lib/units/interactions/interactionext"] = function()
		CST.module("equipment/hooks/interaction"):install()
	end,
}
assert(installers[RequiredScript], "ClientsideStealth: unhandled hook " .. tostring(RequiredScript))()
