local mod_path = ...
local M = {}
local UNITS = {
	"units/clientsidestealth/equipment/ammo_bag",
	"units/clientsidestealth/equipment/doctor_bag",
	"units/clientsidestealth/equipment/bodybags_bag",
	"units/clientsidestealth/equipment/first_aid_kit",
	"units/clientsidestealth/equipment/ecm_jammer",
	"units/clientsidestealth/equipment/trip_mine",
	"units/clientsidestealth/equipment/grenade_crate",
	"units/clientsidestealth/pickups/gen_pku_bodybag_preview/gen_pku_bodybag_preview",
	"units/clientsidestealth/pickups/gen_pku_toolbag_preview/gen_pku_toolbag_preview",
	"units/clientsidestealth/pickups/gen_pku_lootbag_preview/gen_pku_lootbag_preview",
	"units/clientsidestealth/pickups/cg22_pku_bag_preview/cg22_pku_bag_preview",
	"units/clientsidestealth/pickups/cg22_pku_bag_green_preview/cg22_pku_bag_green_preview",
	"units/clientsidestealth/pickups/cg22_pku_bag_yellow_preview/cg22_pku_bag_yellow_preview",
	"units/clientsidestealth/pickups/gen_pku_cage_bag_preview/gen_pku_cage_bag_preview",
	"units/clientsidestealth/pickups/gen_pku_canvasbag_preview/gen_pku_canvasbag_preview",
	"units/clientsidestealth/pickups/gen_pku_explosivesbag_preview/gen_pku_explosivesbag_preview",
	"units/clientsidestealth/pickups/gen_pku_parachute_bag_preview/gen_pku_parachute_bag_preview",
	"units/clientsidestealth/pickups/gen_pku_safe_ovk_bag_preview/gen_pku_safe_ovk_bag_preview",
	"units/clientsidestealth/pickups/gen_pku_safe_wpn_bag_preview/gen_pku_safe_wpn_bag_preview",
	"units/clientsidestealth/pickups/gen_pku_spooky_bag_preview/gen_pku_spooky_bag_preview",
	"units/clientsidestealth/pickups/gen_pku_toolbag_large_preview/gen_pku_toolbag_large_preview",
	"units/clientsidestealth/pickups/gen_safe_secure_dummy_preview/gen_safe_secure_dummy_preview",
	"units/clientsidestealth/pickups/pta_pku_goatbag_preview/pta_pku_goatbag_preview",
	"units/clientsidestealth/pickups/turret_bag_preview/turret_bag_preview",
}

function M.load(resources)
	local unit_type = Idstring("unit")
	for _, path in ipairs(UNITS) do
		BLT.AssetManager:CreateEntry(Idstring(path), unit_type, mod_path .. "assets/" .. path .. ".unit")
	end
	for _, path in ipairs(UNITS) do
		local name = Idstring(path)
		if not resources:has_resource(unit_type, name, resources.DYN_RESOURCES_PACKAGE) then
			resources:load(unit_type, name, resources.DYN_RESOURCES_PACKAGE)
		end
	end
end

return M
