local load_module, Validation, get_runtime, control, restoring_call, transport, world_target, adapters, peers = ...

local Unit = load_module("bags/carry_unit", Validation)
local Records = load_module("bags/records", Validation)
local preview, client
local requests = load_module("bags/carry_requests", function()
	return preview
end, get_runtime, control, Unit, restoring_call)
local retained = load_module("bags/retained", function()
	return client
end, Unit, get_runtime, control, transport, peers)
local areas = load_module("bags/securing/areas")
local secure_host = load_module("bags/securing/host", retained, Records, get_runtime, control, areas, peers)
local secure_client = load_module("bags/securing/client", retained, Records, Unit, get_runtime, control, peers)
local host = load_module("bags/host", retained, Unit, Records, get_runtime, transport, secure_host)
client = load_module("bags/client", retained, requests, Unit, get_runtime, control, transport, world_target)
local lifecycle = load_module(
	"bags/lifecycle",
	{},
	retained,
	host,
	client,
	requests,
	Unit,
	Records,
	get_runtime,
	control,
	world_target,
	function()
		return preview
	end,
	secure_host,
	secure_client
)
preview = load_module("bags/preview", {}, retained, Unit, get_runtime, control, world_target, areas, secure_client)
load_module("bags/hooks/carry", lifecycle, Unit)
load_module("bags/hooks/interaction", host, client, retained, preview)
load_module("bags/hooks/mission", retained)
load_module("bags/hooks/small_loot", client)
load_module("bags/hooks/network", host, client, requests, retained, load_module("shared/from_host"))
load_module("bags/hooks/player", lifecycle, client, preview, retained)

adapters:register("bag", {
	corpse_died = function(unit, corpse)
		requests:corpse_died(unit, corpse)
	end,
	is_suppressed = function(unit)
		return retained.is_suppressed(unit) or preview:is_suppressed(unit) or requests:is_suppressed(unit)
	end,
	has_suppressed_targets = function()
		return retained.has_suppressed_targets()
			or preview:has_suppressed_targets()
			or requests:has_suppressed_targets()
	end,
	holds_peer = function(peer_id)
		return retained.holds_peer(peer_id)
	end,
	awaits_host_records = function()
		return client:awaits_host_records()
	end,
	retry_pending_held = function()
		return client:retry_pending_held()
	end,
})

return { lifecycle = lifecycle, preview = preview }
