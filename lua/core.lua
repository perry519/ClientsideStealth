local existing = rawget(_G, "ClientsideStealth")
if existing then
	return existing
end

local source = debug.getinfo(1, "S").source
local path = string.sub(source, 1, 1) == "@" and string.sub(source, 2) or source
local lua_dir = assert(string.match(path, "^(.*[\\/])"), "ClientsideStealth: cannot resolve module path")
local loaded_modules = {}
local load_chunk = _G.blt and _G.blt.vm and _G.blt.vm.loadfile or loadfile

local function load_module(name, ...)
	assert(type(name) == "string" and string.match(name, "^[%w_/-]+$"), "ClientsideStealth: invalid module path")
	if loaded_modules[name] then
		return loaded_modules[name]
	end

	local module = assert(load_chunk(lua_dir .. name .. ".lua"))(...)
	assert(module ~= nil, "ClientsideStealth: module returned nil: " .. name)
	loaded_modules[name] = module
	return module
end

local function module(name)
	return assert(loaded_modules[name], "ClientsideStealth: module not loaded: " .. name)
end

local Validation = load_module("shared/validation")
local WireSchema = load_module("shared/schema")
local Records = load_module("detection/records", Validation, WireSchema)
local Log = load_module("shared/log")
local Units = load_module("shared/units")
local restoring_call = load_module("shared/restoring_call")
local cop_act = load_module("shared/cop_act")
local adapters = load_module("detection/adapter_registry")
local detection
local function runtime()
	return detection.runtime()
end

local LuaCodec = load_module("network/lua_codec", Records, WireSchema)
local rpc = load_module("network/rpc", Validation, WireSchema, LuaCodec)
local route

if Global then
	if Global.cst_rpc_schema == nil then
		Global.cst_rpc_schema = not Global.initialized and rpc.SCHEMA or false
	end
	Global.cst_transport_epoch = (Global.cst_transport_epoch or 0) + 1
end
local save_path = rawget(_G, "SavePath")
local settings = load_module("session/settings", save_path and save_path .. "ClientsideStealth.json", Log.event)
settings.load()
local transport = load_module(
	"network/transport",
	load_module("network/backends", LuaCodec, rpc, WireSchema.channel),
	function(...)
		return route(...)
	end,
	settings.get("lua_networking") and "lua" or "rpc",
	Global and Global.cst_rpc_schema,
	Global and Global.cst_transport_epoch
)
if transport.restart_required then
	Log.warn_once("native CST RPC schema unavailable or changed since game start; using Lua networking until restart")
end
load_module("network/hooks/handler", rpc, transport)
load_module("network/hooks/notice", transport)

local world_targets = load_module("world_targets/init", load_module, runtime, adapters, restoring_call)
local world_target, npc = world_targets.registry, world_targets.npc
local control = load_module("session/control", runtime, Log.event)
local control_host = load_module("session/control_host", runtime, control)
local control_client = load_module("session/control_client", runtime, control)
local features = load_module(
	"session/features",
	runtime,
	adapters,
	settings,
	control,
	control_host,
	control_client,
	transport,
	Records.target_kinds
)
control.use_features(features)
local peers = load_module("session/peers", runtime, control, features, settings)
features.use_roster(peers)
transport:use_roster(peers)
local peer_delivery =
	load_module("network/peer_delivery", runtime, transport, peers, LuaCodec, WireSchema.channel, Log.event)
local camera_hud = load_module("detection/observations/camera_hud", runtime, adapters, features, transport, Records)
local bags = load_module(
	"bags/init",
	load_module,
	Validation,
	runtime,
	control,
	restoring_call,
	transport,
	world_target,
	adapters,
	peers
)
local bag_lifecycle, bag_preview = bags.lifecycle, bags.preview

detection = load_module(
	"detection/init",
	Records,
	Log.event,
	adapters,
	transport,
	control,
	control_host,
	features,
	camera_hud,
	load_module,
	peers,
	peer_delivery
)

local equipment = load_module("equipment/init", load_module, runtime, control, restoring_call, Log)
local equipment_ecm, equipment_placement = equipment.ecm, equipment.placement
control.add_pause_blocker(bag_lifecycle, "bag")
control.add_pause_blocker(bag_preview, "bag")
control.add_pause_blocker(equipment_placement, "equipment")
control.add_pause_blocker(equipment_ecm, "equipment")

local dart_prediction =
	load_module("guards/init", load_module, runtime, adapters, control, features, world_target, npc, cop_act).dart
local ownership_debug = load_module("ownership_debug/init", runtime, control, bag_preview, Units.is_alive)
load_module("ownership_debug/hooks/contour", ownership_debug)
local npc_reactions = load_module("npc_reactions/init", runtime, control)
load_module("npc_reactions/hooks/player", npc_reactions, restoring_call)
local surrender_action = load_module("npc_reactions/surrender_action", cop_act)
load_module("hooks/cop_movement", dart_prediction, surrender_action)
load_module(
	"npc_reactions/hooks/brain",
	load_module(
		"npc_reactions/surrender",
		runtime,
		control,
		world_target,
		adapters,
		surrender_action,
		npc_reactions,
		npc
	),
	load_module("npc_reactions/surrender_host", runtime, peers)
)
load_module("vehicles/hooks/driving", load_module("vehicles/occupants", world_target, runtime))
load_module("players/hooks/movement", load_module("players/suspicion", runtime, adapters, restoring_call))
load_module("cameras/init", load_module, runtime, features, equipment_ecm, world_target, adapters, camera_hud)
local install_engine_hooks = load_module(
	"detection/hooks/engine",
	load_module("detection/native_ai", runtime, adapters, camera_hud, restoring_call),
	restoring_call
)

local session = load_module(
	"session/init",
	runtime,
	control,
	control_host,
	control_client,
	features,
	transport,
	camera_hud,
	bag_lifecycle,
	bag_preview,
	equipment_placement,
	equipment_ecm,
	dart_prediction,
	ownership_debug,
	peers,
	peer_delivery
)
load_module("session/hooks/network", session)
load_module("hooks/localization", lua_dir .. "../")
load_module("session/hooks/menu", load_module("session/options"), features, settings)
load_module("assets/hooks/resources", load_module("assets/init", lua_dir .. "../"))
detection.Runtime.on_toggle_cleanup(session.cleanup_for_toggle)
detection.Runtime.on_session_changed(session.on_detection_session_change)
route = load_module("network/routing", runtime, bag_lifecycle, camera_hud, transport.channel, peer_delivery)

local function set_enabled(value)
	if type(value) ~= "boolean" or not control_host.set_enabled(value) then
		return false
	end
	settings.set("enabled", value)
	return true
end

local M = {
	adapters = adapters,
	bag_lifecycle = bag_lifecycle,
	bag_preview = bag_preview,
	control = control,
	dart_prediction = dart_prediction,
	equipment_ecm = equipment_ecm,
	equipment_placement = equipment_placement,
	install_engine_hooks = install_engine_hooks,
	load_module = load_module,
	module = module,
	new = detection.new,
	peer_delivery = peer_delivery,
	peers = peers,
	rpc = rpc,
	runtime = detection.runtime,
	session = session,
	set_enabled = set_enabled,
	set_feature = features.set,
	transport = transport,
	world_target = world_target,
}

Log.event("boot", { "schema", rpc.SCHEMA })
rawset(_G, "ClientsideStealth", M)

return M
