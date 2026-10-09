local Schema = {
	enums = {
		target_kind = { "player", "bag", "corpse", "hostage", "vehicle", "npc", "drill", "prop" },
		observer_kind = { "guard", "camera" },
		transition = { "notice", "verified", "identified", "lost", "suspicion", "clear", "alarm" },
	},
}

Schema.channel = setmetatable({
	hello = "cst_v1_hello",
	ready = "cst_v1_ready",
	report = "cst_v1_report",
	resync = "cst_v1_resync",
	state = "cst_v1_state",
	prediction = "cst_v1_prediction",
	camera_hud = "cst_v1_camera_hud",
	bag = "cst_v1_bag",

	peer = "cst_v1_peer",
	peer_relay = "cst_v1_peer_relay",
	peer_receipt = "cst_v1_peer_receipt",
}, {
	__index = function(_, name)
		error("ClientsideStealth: unknown channel " .. tostring(name), 2)
	end,
})

Schema.report = {
	{ "seq", "id" },
	{ "epoch", "id" },
	{ "incarnation", "id" },
	{ "observer_kind", "observer_kind" },
	{ "observer_id", "id" },
	{ "target_kind", "target_kind" },
	{ "target_id", "id" },
	{ "transition", "transition" },
	{ "value", "scalar" },
	{ "observer_generation", "optional_id" },
	{ "config_revision", "optional_id" },
}

Schema.state = {

	begin = {
		{ "owner_count", "count" },
		{ "camera_count", "count" },
		{ "target_count", "count", 0 },
		{ "observation_count", "count", 0 },
		{ "observer_count", "count", 0 },

		{ "base_seq", "id", 0 },
		{ "removal_count", "count", 0 },
	},
	owner = {
		{ "kind", "target_kind" },
		{ "id", "id" },
		{ "incarnation", "id" },
		{ "owner_peer_id", "id" },
		{ "epoch", "id" },
		{ "pending_owner_peer_id", "optional_id" },
	},
	target = {
		{ "kind", "target_kind" },
		{ "id", "id" },
		{ "incarnation", "id" },
		{ "presets", "presets" },
		{ "team_id", "token" },
		{ "reaction", "number" },
		{ "notice_delay_mul", "number" },
		{ "verification_interval", "number" },
		{ "release_delay", "number" },
		{ "uncover_range", "number" },
		{ "max_range", "number" },
		{ "notice_requires_fov", "optional_boolean" },
		{ "verification_requires_fov", "optional_boolean" },
		{ "config_revision", "optional_id" },
	},
	observation = {
		{ "observer_kind", "observer_kind" },
		{ "observer_id", "id" },
		{ "target_kind", "target_kind" },
		{ "target_id", "id" },
		{ "incarnation", "id" },
		{ "owner_peer_id", "id" },
		{ "epoch", "id" },
		{ "seq", "id" },
		{ "transition", "transition" },
		{ "value", "scalar" },
		{ "notice_progress", "number" },
		{ "uncover_progress", "number" },
		{ "identified", "optional_boolean" },
		{ "verified", "optional_boolean" },
		{ "suspicion_progress", "number" },
		{ "alarmed", "optional_boolean" },
	},
	camera = {
		{ "id", "id" },
		{ "enabled", "boolean" },
		{ "yaw", "number" },
		{ "pitch", "number" },
		{ "fov", "number" },
		{ "detection_range", "number" },
		{ "suspicion_range", "number" },
		{ "delay_min", "number" },
		{ "delay_max", "number" },
		{ "team_id", "token" },
		{ "update_position", "optional_boolean" },
		{ "alarm", "optional_boolean" },
		{ "ecm", "optional_boolean" },
	},
	commit = {},
	observer = {
		{ "kind", "observer_kind" },
		{ "id", "id" },
		{ "generation", "id" },
	},
	remove = {
		{ "key", "key" },
	},
}

return Schema
