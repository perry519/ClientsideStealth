local Records, State, log_event, adapters, transport, control, control_host, features, camera_hud, load_module, peers, peer_delivery =
	...
local Runtime = {}

Runtime.PROTOCOL_TOKEN = "3"
local Channel = transport.channel
Runtime.__index = Runtime
local runtime_instance
local engine_alive = load_module("shared/units").is_alive
local copy_record = load_module("detection/copy").shallow_copy
local HANDOFF_TIMEOUT = 5

local function log_report(event, report, peer_id)
	if
		event ~= "report_apply_failed"
		and report.seq ~= 1
		and (report.transition == "notice" or report.transition == "suspicion")
	then
		return
	end
	log_event(event, {
		"peer",
		peer_id,
		"observer",
		State.object_key(report.observer_kind, report.observer_id),
		"target",
		State.object_key(report.target_kind, report.target_id),
		"transition",
		report.transition,
		"seq",
		report.seq,
		"epoch",
		report.epoch,
		"value",
		report.value,
	})
end

load_module("detection/session", Runtime, State, engine_alive, log_event, adapters, transport, camera_hud, features)
load_module(
	"detection/synchronization/delivery",
	Runtime,
	Records,
	State,
	engine_alive,
	HANDOFF_TIMEOUT,
	copy_record,
	log_event,
	adapters,
	transport,
	control_host,
	camera_hud
)
load_module("detection/synchronization/client", Runtime, engine_alive, log_event, adapters, transport)
load_module("detection/registry/unit_bindings", Runtime, State, engine_alive, copy_record, adapters, camera_hud)
load_module(
	"detection/attention",
	Runtime,
	copy_record,
	engine_alive,
	adapters,
	load_module("shared/restoring_call"),
	State.object_key
)
load_module(
	"detection/predictions/local_views",
	Runtime,
	Records,
	State,
	engine_alive,
	copy_record,
	adapters,
	transport,
	control,
	peers
)
load_module(
	"detection/predictions/settlement",
	Runtime,
	Records,
	State,
	engine_alive,
	copy_record,
	adapters,
	transport,
	load_module("shared/restoring_call")
)
load_module("detection/predictions/npc_alerts", Runtime, State, engine_alive, control, adapters)
load_module("detection/predictions/decisions", Runtime, Records, State, copy_record, transport, adapters)
load_module("detection/predictions/alert_roots", Runtime, Records, State, engine_alive, adapters)
load_module("detection/observations/reporting", Runtime, State, engine_alive, log_report, adapters, transport)
load_module("detection/observations/views", Runtime, Records, State, engine_alive, copy_record)
load_module(
	"detection/observations/remote",
	Runtime,
	Records,
	State,
	engine_alive,
	adapters,
	peers,
	peer_delivery,
	load_module("shared/schema").report
)

local function get_runtime()
	if runtime_instance then
		return runtime_instance
	end

	local runtime = setmetatable({
		current_session = false,
		host_peer_id = 1,
		local_peer_id = 1,
		snapshot_seq = 0,
	}, Runtime)
	runtime.identify_synced_attention = function(attention)
		return runtime:_identify_attention(attention)
	end

	runtime.core = State.new({
		host_peer_id = runtime.host_peer_id,
		is_host = Network and Network:is_server() or false,
		local_peer_id = runtime.local_peer_id,
		on_camera_config = function(record)
			runtime:_on_camera_config(record)
		end,
		on_camera_enabled = function(id)
			runtime:_on_camera_enabled(id)
		end,
		on_camera_transition = function(report, observer, target)
			return runtime:_on_camera(report, observer, target)
		end,
		on_cleanup = function(old, new)
			runtime:_on_cleanup(old, new)
		end,
		on_guard_transition = function(report, observer, target)
			return runtime:_on_guard(report, observer, target)
		end,
		on_observation = function(report, observer, target)
			runtime:_on_observation(report, observer, target)
		end,
		on_observation_removed = function(observation)
			runtime:_on_observation_removed(observation)
		end,
		on_owner = function(record, old)
			runtime:_on_owner(record, old)
		end,
		on_report_accepted = function(report, peer_id)
			log_report("report_accepted", report, peer_id)
		end,
		on_report_rejected = function(peer_id, reason, report)
			log_event("report_rejected", { "peer", peer_id, "reason", reason })
			runtime:reject_remote_observation(peer_id, report, reason)
			if reason == "apply_failed" then
				runtime:mark_state_dirty()
			end
		end,
		on_snapshot_commit = function()
			runtime:_on_snapshot_commit()
			runtime:prune_remote_observations()
		end,
		on_snapshot_base_missing = function()
			runtime:request_resync()
		end,
		on_snapshot_begin = function(snapshot_seq)
			runtime:_on_snapshot_begin(snapshot_seq)
		end,
		on_target_config = function(record, target)
			return runtime:_on_target_config(record, target)
		end,
		owner_eligible = function(peer_id, kind)
			return runtime:can_own(peer_id, kind)
		end,
		peer_eligible = function(peer_id)
			return runtime:_peer_eligible(peer_id)
		end,
		prediction_source_authorized = function(peer_id, claim)
			return runtime:prediction_source_authorized(peer_id, claim)
		end,
		report_eligible = function(report, observer, target)
			return runtime:_report_eligible(report, observer, target)
		end,
	})

	runtime_instance = runtime
	runtime:refresh_session()
	runtime:sync_players()

	return runtime
end

function Runtime:is_host()
	return self.core.is_host
end

function Runtime:authority_matches()
	return self.core.is_host == Network:is_server()
end

local HOST_PREDICTION_OPS = { claim = true, observe = true, cancel = true, settled = true }
local CLIENT_PREDICTION_OPS = { identity = true, decision = true, ack = true }

function Runtime:receive_record(peer_id, channel, record)
	if self.core.is_host then
		if channel == Channel.hello then
			return self:receive_hello(peer_id, record)
		elseif channel == Channel.ready then
			return self:receive_ready_record(peer_id, record)
		elseif channel == Channel.report and self:is_peer_capable(peer_id) then
			return self.core:receive_report_record(peer_id, record)
		elseif channel == Channel.resync and self:is_peer_capable(peer_id) then
			return self:receive_resync(peer_id)
		elseif channel == Channel.prediction and HOST_PREDICTION_OPS[record.op] and self:is_peer_capable(peer_id) then
			return self:receive_prediction_record(peer_id, record)
		end
	elseif channel == Channel.state then
		return self.core:receive_state_record(peer_id, record)
	elseif channel == Channel.prediction and CLIENT_PREDICTION_OPS[record.op] and self:is_peer_capable(peer_id) then
		return self:receive_prediction_record(peer_id, record)
	end
	return false
end

Runtime.register_remote_observations(get_runtime)

return { Runtime = Runtime, runtime = get_runtime }
