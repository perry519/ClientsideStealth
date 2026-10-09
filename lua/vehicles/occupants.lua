local world_target, get_runtime = ...
local M = {}

local function target_id(unit)
	local id = unit and unit:id()

	return id ~= -1 and id or nil
end

local function peer_id_for(unit, session)
	local peer = alive(unit) and session and session:peer_by_unit(unit)

	return peer and peer:id() or nil
end

local function vehicle_owner(self)
	local session = managers.network and managers.network:session()
	local driver = self._seats and self._seats.driver
	local driver_peer_id = driver and peer_id_for(driver.occupant, session)

	if driver_peer_id then
		return driver_peer_id, driver.occupant
	end

	local lowest_peer_id
	local owner_unit

	for _, seat in pairs(self._seats or {}) do
		local peer_id = peer_id_for(seat.occupant, session)

		if peer_id and (not lowest_peer_id or peer_id < lowest_peer_id) then
			lowest_peer_id = peer_id
			owner_unit = seat.occupant
		end
	end

	return lowest_peer_id or get_runtime().host_peer_id, owner_unit
end

function M.removed(self)
	local runtime = get_runtime()
	local id = target_id(self._unit)
	if id and runtime:unregister_target("vehicle", id) and Network:is_server() then
		runtime:mark_state_dirty()
	end
end

function M.seats_changed(self)
	local runtime = get_runtime()
	local unit = self._unit
	local id = target_id(unit)

	if not id then
		return
	end

	if self:num_players_inside() == 0 or not unit:attention() then
		self._cst_detection_owner = nil
		M.removed(self)
		return
	end

	local owner, source_unit = vehicle_owner(self)
	runtime:register_target("vehicle", id, unit)
	local changed = self._cst_detection_owner ~= owner
	self._cst_detection_owner = owner
	local spec
	if changed then
		local config = world_target.config(unit)
		if config then
			self._cst_detection_serial = (self._cst_detection_serial or 0) + 1
			spec = {
				kind = "vehicle",
				unit = unit,
				canonical_unit = unit,
				id = id,
				owner_peer_id = owner,
				source_unit = source_unit,
				cause = "vehicle_owner",
				config = config,
				native_key = "vehicle:" .. id .. ":" .. self._cst_detection_serial,
			}
		end
	end
	local session = managers.network and managers.network:session()
	local local_peer = session and session.local_peer and session:local_peer()
	if not Network:is_server() and spec and local_peer and owner == local_peer:id() then
		spec.attention = world_target.prediction_attention(unit, spec.config)
		runtime:predict_target(spec)
	end

	if Network:is_server() then
		local record = runtime:assign_owner("vehicle", id, owner)

		if record then
			runtime:mark_state_dirty()
		end
		if spec then
			runtime:confirm_prediction(spec)
		end
	end
end

return M
