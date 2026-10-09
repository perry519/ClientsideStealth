local equipment_ecm, get_runtime, control, Supplies, Devices = ...
local M = {}

M.MAX_PENDING = 8
M.TIMEOUT = 10
M.POSITION_TOLERANCE = 2
M.ROTATION_TOLERANCE = 2
M.pending = {}

function M:busy_for_pause()
	return #self.pending > 0
end
M.seen_units = setmetatable({}, { __mode = "k" })

local DUMMY_UNITS = {
	ammo_bag = "units/payday2/equipment/gen_equipment_ammobag/gen_equipment_ammobag_dummy_unit",
	bodybags_bag = "units/payday2/equipment/gen_equipment_bodybags_bag/gen_equipment_bodybags_bag_dummy",
	doctor_bag = "units/payday2/equipment/gen_equipment_medicbag/gen_equipment_medicbag_dummy_unit",
	ecm_jammer = "units/payday2/equipment/gen_equipment_jammer/gen_equipment_jammer_dummy",
	first_aid_kit = "units/pd2_dlc_old_hoxton/equipment/gen_equipment_first_aid_kit/gen_equipment_first_aid_kit_dummy",
	grenade_crate = "units/pd2_dlc_mxm/equipment/gen_equipment_grenade_crate/gen_equipment_grenade_crate_dummy",
	spy_camera = "units/pd2_dlc_esp/equipment/esp_equipment_spy_camera/esp_equipment_spy_camera_dummy",
	trip_mine = "units/payday2/equipment/gen_equipment_tripmine/gen_equipment_tripmine_dummy",
}

local REAL_UNITS = {
	ammo_bag = "units/payday2/equipment/gen_equipment_ammobag/gen_equipment_ammobag",
	bodybags_bag = "units/payday2/equipment/gen_equipment_bodybags_bag/gen_equipment_bodybags_bag",
	doctor_bag = "units/payday2/equipment/gen_equipment_medicbag/gen_equipment_medicbag",
	first_aid_kit = "units/pd2_dlc_old_hoxton/equipment/gen_equipment_first_aid_kit/gen_equipment_first_aid_kit",
	grenade_crate = "units/pd2_dlc_mxm/equipment/gen_equipment_grenade_crate/gen_equipment_grenade_crate",
	trip_mine = "units/payday2/equipment/gen_equipment_tripmine/gen_equipment_tripmine",
}

local function wall_time()
	return TimerManager:wall():time()
end

local function current_session()
	return managers.network and managers.network:session()
end

local function local_peer_id(session)
	local peer = session and session:local_peer()
	return peer and peer:id() or nil
end

local function delete_dummy(record)
	if record and record.proxy then
		record.proxy:destroy(record)
	end
	if record and alive(record.dummy) then
		World:delete_unit(record.dummy)
	end
	if record then
		record.dummy = nil
	end
end

local function angle_distance(left, right)
	local difference = math.abs(left - right) % 360
	return math.min(difference, 360 - difference)
end

local function same_position(position, unit)
	return mvector3.distance_sq(position, unit:position()) <= M.POSITION_TOLERANCE * M.POSITION_TOLERANCE
end

local function same_transform(record, unit)
	local rotation = unit:rotation()
	return same_position(record.position, unit)
		and angle_distance(record.rotation:yaw(), rotation:yaw()) <= M.ROTATION_TOLERANCE
		and angle_distance(record.rotation:pitch(), rotation:pitch()) <= M.ROTATION_TOLERANCE
		and angle_distance(record.rotation:roll(), rotation:roll()) <= M.ROTATION_TOLERANCE
end

local function kind_for(unit)
	if not unit or not unit.name then
		return nil
	end
	local name = unit:name()
	for kind, asset in pairs(REAL_UNITS) do
		if name == Idstring(asset) then
			return kind
		end
	end
	return nil
end

local function matching_indices(kind, unit, owner)
	local matches = {}
	for index, record in ipairs(M.pending) do
		if
			not record.confirmed
			and record.kind == kind
			and (owner == nil or record.owner == owner)
			and same_transform(record, unit)
		then
			matches[#matches + 1] = index
		end
	end
	return matches
end

local function remove_matches(matches)
	for match = #matches, 1, -1 do
		local index = matches[match]
		delete_dummy(M.pending[index])
		table.remove(M.pending, index)
	end
end

local function confirm(index, unit)
	local record = M.pending[index]
	record.confirmed = true
	if record.proxy:arrive(record, unit) then
		return true
	end
	remove_matches({ index })
	return true
end

local function remove_first(kind)
	for index, record in ipairs(M.pending) do
		if record.kind == kind then
			delete_dummy(record)
			table.remove(M.pending, index)
			return true
		end
	end
	return false
end

local function confirm_first(kind, unit)
	for index, record in ipairs(M.pending) do
		if record.kind == kind and not record.confirmed then
			if alive(unit) then
				return confirm(index, unit)
			end
			remove_matches({ index })
			return false
		end
	end
	return false
end

local function attachment_body(unit, unit_id, body_index)
	if not alive(unit) and unit_id ~= nil and unit_id ~= "" then
		if type(unit_id) == "string" and string.find(unit_id, "ISNUMBER", 1, true) then
			unit_id = string.gsub(unit_id, "ISNUMBER", "")
			unit_id = tonumber(unit_id)
		end
		unit = managers.worlddefinition and managers.worlddefinition:get_unit(unit_id)
	end
	return alive(unit) and unit:body(body_index) or nil
end

local function retain_ecm(
	equipment,
	attach_unit,
	attach_id,
	body_index,
	world_rotation,
	relative_position,
	relative_rotation,
	upgrade_level
)
	local body = attachment_body(attach_unit, attach_id, body_index)
	local record = alive(body) and M:retain(equipment, "ecm_jammer", nil, world_rotation, nil, upgrade_level)
	if not record then
		return false
	end
	local dummy = record.dummy
	record.attachment_body = body
	body:unit():link(body:root_object():name(), dummy, dummy:orientation_object():name())
	dummy:set_local_position(relative_position)
	dummy:set_local_rotation(relative_rotation)
	return true
end

function M:retain(equipment, kind, now, request_rotation, request_position, upgrade_level, bullet_storm_level)
	if not control.allows_new_work("equipment") then
		return false
	end
	local session = current_session()
	local dummy = equipment and equipment._dummy_unit
	if
		self.session ~= session
		or not DUMMY_UNITS[kind]
		or not Network:is_client()
		or rawget(_G, "IS_VR")
		or not session
		or not alive(dummy)
		or not dummy.name
		or dummy:name() ~= Idstring(DUMMY_UNITS[kind])
		or #self.pending >= self.MAX_PENDING
		or kind == "first_aid_kit" and rawget(_G, "ClientsidedUppers")
	then
		return false
	end

	local owner = local_peer_id(session)
	if not owner then
		return false
	end

	if request_position then
		dummy:set_position(request_position)
	end
	if request_rotation then
		dummy:set_rotation(request_rotation)
	end
	local matches = matching_indices(kind, dummy, owner)
	if #matches > 0 then
		remove_matches(matches)
		return false
	end
	now = now or wall_time()
	local record = {
		session = session,
		kind = kind,
		owner = owner,
		position = mvector3.copy(request_position or dummy:position()),
		rotation = mrotation.copy(request_rotation or dummy:rotation()),
		dummy = dummy,
		expires_at = now + self.TIMEOUT,
	}
	record.proxy = (kind == "ecm_jammer" or kind == "trip_mine" or kind == "spy_camera") and Devices or Supplies
	if not record.proxy:spawn(record, upgrade_level, bullet_storm_level) then
		return false
	end
	equipment._dummy_unit = nil
	self.pending[#self.pending + 1] = record
	return record
end

local function arrive(self, kind, unit, owner)
	if get_runtime().enabled == false then
		return false
	end
	local session = current_session()
	if self.session ~= session or not kind or not alive(unit) or self.seen_units[unit] then
		return false
	end
	self.seen_units[unit] = true
	if owner ~= local_peer_id(session) then
		return false
	end

	local matches = matching_indices(kind, unit, owner)
	if #matches == 0 then
		return false
	end

	if #matches == 1 then
		return confirm(matches[1], unit)
	end
	remove_matches(matches)
	return false
end

function M:arrive(kind, unit, owner)
	local matched = arrive(self, kind, unit, owner)
	local base = alive(unit) and unit:base()
	if base and base._cst_deferred_drop then
		base._cst_deferred_drop = nil
		if not matched then
			unit:sound_source():post_event("ammo_bag_drop")
		end
	end
	return matched
end

function M:grenade_arrive(unit, owner)
	return owner ~= nil and self:arrive("grenade_crate", unit, owner) or false
end

function M:update(now)
	if self.session ~= current_session() then
		return
	end
	for index = #self.pending, 1, -1 do
		local record = self.pending[index]
		if record.proxy:update(record, now) or record.attachment_body and not alive(record.attachment_body) then
			delete_dummy(record)
			table.remove(self.pending, index)
		end
	end
end

function M:clear_pending()
	for index = #self.pending, 1, -1 do
		delete_dummy(self.pending[index])
		self.pending[index] = nil
	end
end

function M:reset(session)
	self:clear_pending()
	self.session = session
	self.seen_units = setmetatable({}, { __mode = "k" })
end

function M:peer_lost(peer_id)
	for index = #self.pending, 1, -1 do
		if self.pending[index].owner == peer_id then
			delete_dummy(self.pending[index])
			table.remove(self.pending, index)
		end
	end
end

local function local_equipment()
	local player = managers.player and managers.player:player_unit()
	return alive(player) and player.equipment and player:equipment() or nil
end

function M:sent(kind, position, request_rotation, use_request_position, upgrade_level, bullet_storm_level)
	local equipment = local_equipment()
	local dummy = equipment and equipment._dummy_unit
	if alive(dummy) and (use_request_position or same_position(position, dummy)) then
		self:retain(
			equipment,
			kind,
			nil,
			request_rotation,
			use_request_position and position or nil,
			upgrade_level,
			bullet_storm_level
		)
	end
end

function M:ecm_sent(
	attach_unit,
	attach_id,
	body_index,
	_,
	world_rotation,
	relative_position,
	relative_rotation,
	upgrade
)
	equipment_ecm:request_sent(upgrade)
	local equipment = local_equipment()
	if equipment and alive(equipment._dummy_unit) then
		retain_ecm(
			equipment,
			attach_unit,
			attach_id,
			body_index,
			world_rotation,
			relative_position,
			relative_rotation,
			upgrade
		)
	end
end

function M:equipment_setup(unit, peer_id)
	self:arrive(kind_for(unit), unit, peer_id)
end

function M:trip_mine_activated(unit)
	if kind_for(unit) == "trip_mine" then
		self:arrive("trip_mine", unit, local_peer_id(current_session()))
	end
end

function M:host_placed(kind, unit)
	if self.session ~= current_session() then
		return
	end
	if kind == "ecm_jammer" then
		equipment_ecm:request_placed(unit)
	end
	confirm_first(kind, unit)
end

function M:host_place_failed(kind)
	if self.session ~= current_session() then
		return
	end
	if kind == "ecm_jammer" then
		equipment_ecm:request_failed()
	end
	remove_first(kind)
end

function M:predicted_trip_mine(unit, peer_id)
	return Network:is_client()
		and alive(unit)
		and kind_for(unit) == "trip_mine"
		and self.session == current_session()
		and peer_id == local_peer_id(self.session)
		and #matching_indices("trip_mine", unit, peer_id) == 1
end

function M:predicted_bag(kind, unit)
	return Network:is_client()
		and kind_for(unit) == kind
		and self.session == current_session()
		and #matching_indices(kind, unit) > 0
end

return M
