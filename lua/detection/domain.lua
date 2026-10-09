local Records, load_module = ...
local Core = {}
Core.__index = Core
local copy_record = load_module("detection/copy").shallow_copy

local object_key = Records.object_key

local function new(options)
	options = options or {}
	local self = setmetatable({}, Core)
	self.options = options
	self.host_peer_id = options.host_peer_id or 1
	self.local_peer_id = options.local_peer_id or self.host_peer_id
	self.is_host = options.is_host == true
	self:reset()
	return self
end

function Core:reset()
	self:_reset_registry()
	self:_reset_observations()
	self:_reset_ownership()
	self:_reset_synchronization()
	self:_reset_prediction_state()
end

function Core:set_session_identity(peer_id, is_host)
	self.local_peer_id = peer_id
	self.is_host = is_host == true
end

load_module("detection/registry/registrations", Core, Records, object_key, copy_record)
load_module("detection/ownership/ledger", Core, Records, object_key, copy_record)
load_module("detection/observations/transitions", Core, Records, object_key, copy_record)
load_module("detection/synchronization/snapshot", Core, Records, object_key, copy_record)
load_module("detection/scopes", Core)
load_module("detection/predictions/claims", Core, Records, object_key)

return {
	Core = Core,
	new = new,
	object_key = object_key,
}
