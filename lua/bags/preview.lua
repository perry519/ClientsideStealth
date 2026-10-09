local M, retained, Unit, get_runtime, control, world_target, secure_areas, secure = ...

M.MAX_PENDING = 4
M.TIMEOUT = 10
M.POSITION_TOLERANCE = 2

M.CAPTURE_TIMEOUT = 10
M.pending = {}

M.captured = setmetatable({}, { __mode = "k" })

M.secured = setmetatable({}, { __mode = "k" })

M.watched = setmetatable({}, { __mode = "k" })

function M:busy_for_pause()
	return #self.pending > 0 or next(self.captured) ~= nil
end
M.awaiting_prediction = {}

function M:native_drop_sent(token, carry_id)
	if not token then
		return
	end
	for _, record in ipairs(self.pending) do
		if not record.native_key and not record.native and record.carry_id == carry_id then
			record.native_key = token
			if record.config then
				local runtime = get_runtime()
				record.prediction = runtime:predict_target({
					kind = "bag",
					unit = record.unit,
					owner_peer_id = record.owner,
					source_unit = managers.player:player_unit(),
					cause = "bag_drop",
					native_key = token,
					config = record.config,
					attention = world_target.prediction_attention(record.unit, record.config),
				})
			end
			return
		end
	end
end

local GENERIC_LOOT_BAG = "units/payday2/pickups/gen_pku_lootbag/gen_pku_lootbag"
local PREVIEW_UNITS = {}
for _, path in ipairs({
	GENERIC_LOOT_BAG,
	"units/payday2/pickups/gen_pku_bodybag/gen_pku_bodybag",
	"units/payday2/pickups/gen_pku_toolbag/gen_pku_toolbag",
	"units/payday2/pickups/gen_pku_canvasbag/gen_pku_canvasbag",
	"units/payday2/pickups/gen_pku_cage_bag/gen_pku_cage_bag",
	"units/payday2/pickups/gen_pku_toolbag_large/gen_pku_toolbag_large",
	"units/pd2_dlc1/pickups/gen_pku_explosivesbag/gen_pku_explosivesbag",
	"units/pd2_dlc_cg22/pickups/cg22_pku_bag/cg22_pku_bag",
	"units/pd2_dlc_cg22/pickups/cg22_pku_bag/cg22_pku_bag_green",
	"units/pd2_dlc_cg22/pickups/cg22_pku_bag/cg22_pku_bag_yellow",
	"units/pd2_dlc_help/pickups/gen_pku_spooky_bag/gen_pku_spooky_bag",
	"units/pd2_dlc_jerry/pickups/gen_pku_parachute_bag/gen_pku_parachute_bag",
	"units/pd2_dlc_jolly/pickups/gen_pku_safe_ovk_bag/gen_pku_safe_ovk_bag",
	"units/pd2_dlc_jolly/pickups/gen_pku_safe_wpn_bag/gen_pku_safe_wpn_bag",
	"units/pd2_dlc_jolly/pickups/gen_safe_secure_dummy/gen_safe_secure_dummy",
	"units/pd2_dlc_peta/pickups/pta_pku_goatbag/pta_pku_goatbag",
	"units/pd2_dlc_ranc/pickups/ranc_pku_turretbag/turret_bag",
}) do
	local model = path:match("([^/]+)$")
	PREVIEW_UNITS[path] = "units/clientsidestealth/pickups/" .. model .. "_preview/" .. model .. "_preview"
end

PREVIEW_UNITS["units/payday2/pickups/gen_pku_toolbag_large/gen_pku_toolbag_large_2"] =
	PREVIEW_UNITS["units/payday2/pickups/gen_pku_toolbag_large/gen_pku_toolbag_large"]
PREVIEW_UNITS["units/payday2/pickups/gen_pku_toolbag_large/gen_pku_toolbag_large_3"] =
	PREVIEW_UNITS["units/payday2/pickups/gen_pku_toolbag_large/gen_pku_toolbag_large"]
PREVIEW_UNITS["units/pd2_dlc_cane/pickups/gen_pku_toolbag_global_event/gen_pku_toolbag_global_event"] =
	PREVIEW_UNITS["units/payday2/pickups/gen_pku_toolbag/gen_pku_toolbag"]

local function current_session()
	return managers.network and managers.network:session()
end

local function local_peer_id()
	local session = current_session()
	local peer = session and session:local_peer()
	return peer and peer:id() or nil
end

local function now()
	return TimerManager:wall():time()
end

local function stop_collision_tracking(record)
	for index = 0, record.unit:num_bodies() - 1 do
		record.unit:body(index):set_collision_script_tag(Idstring(""))
	end
end

local function track_collision(record)
	local unit = record.unit
	local function collision(_, _, _, other)
		if other and (other:key() == unit:key() or (alive(record.native) and other:key() == record.native:key())) then
			unit:set_body_collision_callback(collision)
			return
		end
		record.contacted = true
		if record.pose_transferred and alive(record.native) and record.native:interaction() then
			record.native:interaction()._has_modified_timer = nil
		end
		stop_collision_tracking(record)
	end
	unit:set_body_collision_callback(collision)
	for index = 0, unit:num_bodies() - 1 do
		local body = unit:body(index)
		body:set_collision_script_tag(Idstring("throw"))
		body:set_collision_script_filter(1)
		body:set_collision_script_quiet_time(1)
	end
end

local function prediction_unit(record)
	return record.prediction and record.prediction.unit or record.unit
end

local function exact_native(record)
	local decision = record.prediction and record.prediction.decision
	return record.native or decision and record.candidates and record.candidates[decision.id]
end

local function restore_bodies(record)
	for _, body in ipairs(record.dynamic_bodies or {}) do
		body:set_dynamic()
	end
	record.dynamic_bodies = nil
end

local function restore_native(record)
	local native = record.native
	if not alive(native) or retained.is_suppressed(native) then
		return
	end
	native:set_visible(record.native_visible)
	if record.pose_transferred and record.contacted and native:interaction() then
		native:interaction()._has_modified_timer = nil
	end
	if not record.secure_confirmed and record.native_interaction_active ~= nil and native:interaction() then
		native:interaction():set_active(record.native_interaction_active, false)
	end
end

local function delete_preview(record, keep_prediction)
	local native = record and record.native
	if alive(native) and not retained.is_suppressed(native) then
		restore_bodies(record)
	end
	if record and alive(record.unit) then
		stop_collision_tracking(record)
		if keep_prediction then
			record.unit:set_visible(false)
		else
			World:delete_unit(record.unit)
		end
	end
	if record and not keep_prediction then
		record.unit = nil
	end
end

function M:predict(data, position, rotation, direction, level, zipline, token)
	local runtime = get_runtime()

	if not control.allows_new_work("bag_handling") or not control.allows_new_work("bag") then
		return false
	end
	local carry_id = data and (data.carry_id or data._carry_id)
	local owner = local_peer_id()
	if
		not Network:is_client()
		or not runtime:is_peer_capable(runtime.host_peer_id)
		or alive(zipline)
		or not owner
		or #self.pending >= self.MAX_PENDING
	then
		return false
	end
	local carry_tweak = carry_id and tweak_data.carry[carry_id]
	local multiplier = carry_id and managers.player and Unit.throw_multiplier(managers.player, carry_id, level)
	if not carry_tweak or not multiplier or not position or not rotation or not direction then
		return false
	end
	local preview_name = PREVIEW_UNITS[carry_tweak.unit or GENERIC_LOOT_BAG]
	if not preview_name then
		return false
	end
	local name = Idstring(preview_name)
	if not PackageManager:has(Idstring("unit"), name) then
		return false
	end
	local sync = PackageManager:unit_data(name):network_sync()
	if sync ~= "none" and sync ~= "client" then
		return false
	end
	position = mvector3.copy(position)
	local unit = World:spawn_unit(name, position, rotation)
	if not alive(unit) then
		return false
	end
	if unit:id() ~= -1 then
		World:delete_unit(unit)
		return false
	end
	local carry = unit:carry_data()
	if not carry then
		World:delete_unit(unit)
		return false
	end
	carry:set_carry_id(carry_id)
	local config = world_target.config(unit)
	if not config then
		World:delete_unit(unit)
		return false
	end
	unit:set_extension_update_enabled(Idstring("carry_data"), false)
	local interaction = unit:interaction()
	if interaction then
		interaction:set_active(true, false)
		managers.interaction:remove_unit(unit)
	end
	carry:set_carry_id(nil)
	local attention = unit:attention()
	if attention then
		local ids = {}
		for id in pairs(attention:attention_data() or {}) do
			ids[#ids + 1] = id
		end
		for _, id in ipairs(ids) do
			attention:remove_attention(id)
		end
	end
	local record = {
		carry_id = carry_id,
		config = config,
		expires_at = now() + self.TIMEOUT,
		owner = owner,
		position = position,
		unit = unit,
	}
	track_collision(record)
	unit:push(100, direction * (600 * multiplier))
	self.pending[#self.pending + 1] = record
	if token then
		self:native_drop_sent(token, carry_id)
	end
	return true
end

local function bind_native(record)
	local decision = record.prediction and record.prediction.decision
	local native = decision and record.candidates and record.candidates[decision.id]
	if not alive(native) then
		return false
	end
	local preview = record.unit
	record.native, record.native_visible = native, native:visible()
	local interaction = native:interaction()
	if interaction then
		record.native_interaction_active = interaction:active()
		interaction:set_active(false, false)
	end
	record.transfer_frames = 0
	if not record.secure_pending then
		record.expires_at = now() + M.TIMEOUT
	end
	for index = 0, preview:num_bodies() - 1 do
		preview:body(index):set_disable_collision_with_unit(native)
	end
	native:set_visible(false)
	if record.secure_pending then
		get_runtime():clear_local_detection(native)
	end
	record.candidates = nil
	return true
end

function M:reconcile(unit, carry_id, position, peer_id)
	if get_runtime().enabled == false then
		return false
	end
	if not alive(unit) or peer_id ~= local_peer_id() or not position then
		return false
	end
	for index = #self.pending, 1, -1 do
		local record = self.pending[index]
		if
			not record.native
			and alive(record.unit)
			and record.owner == peer_id
			and record.carry_id == carry_id
			and mvector3.distance(record.position, position) <= self.POSITION_TOLERANCE
		then
			record.candidates = record.candidates or {}
			record.candidates[unit:id()] = unit
			if not record.prediction and record.native_key then
				delete_preview(record)
				table.remove(self.pending, index)
			elseif
				record.prediction
				and record.prediction.decision
				and record.prediction.decision.id == unit:id()
				and bind_native(record)
			then
				return true
			end
		end
	end
	return false
end

function M:reject(carry_id)
	for index = #self.pending, 1, -1 do
		if self.pending[index].carry_id == carry_id and not self.pending[index].native then
			if self.pending[index].prediction then
				get_runtime():cancel_prediction_for_unit(prediction_unit(self.pending[index]), "native_drop_rejected")
			end
			restore_native(self.pending[index])
			delete_preview(self.pending[index])
			table.remove(self.pending, index)
			return true
		end
	end
	return false
end

function M:prepare_pickup(unit)
	secure:cancel(unit)
	self.watched[unit] = nil
	for _, list in ipairs({ self.pending, self.awaiting_prediction }) do
		for index = #list, 1, -1 do
			local record = list[index]
			if record.native == unit then
				secure:cancel(record.unit)
				get_runtime():retire_prediction_for_unit(prediction_unit(record), "native_pickup")
				restore_native(record)
				delete_preview(record)
				table.remove(list, index)
			end
		end
	end
end

local function finish_handoff(record, time)
	local native, preview = record.native, record.unit
	if not alive(native) or retained.is_suppressed(native) then
		return true
	end
	if record.transfer_frames then
		record.transfer_frames = record.transfer_frames + 1
		if record.transfer_frames == 1 then
			record.dynamic_bodies = {}
			for index = 0, native:num_bodies() - 1 do
				local body = native:body(index)
				if body:dynamic() then
					record.dynamic_bodies[#record.dynamic_bodies + 1] = body
					body:set_keyframed()
				end
			end
			return false
		end
		if record.transfer_frames == 2 or record.transfer_frames == 3 then
			native:set_position(preview:position())
			native:set_rotation(preview:rotation())
			for index = 0, preview:num_bodies() - 1 do
				local source, target = preview:body(index), native:body(index)
				target:set_position(source:position())
				target:set_rotation(source:rotation())
				target:set_velocity(source:velocity())
				target:set_angular_velocity(source:angular_velocity())
			end
			record.pose_transferred = true
			local interaction = native:interaction()
			if interaction then
				interaction._has_modified_timer = not record.contacted or nil
				if record.native_interaction_active and not interaction:active() then
					interaction:set_active(true, false)
				end
			end
			if record.follow_until_settled and record.transfer_frames == 3 then
				if mvector3.length(preview:body(0):velocity()) > 50 then
					record.settled_at = nil
				else
					record.settled_at = record.settled_at or time
				end
				if not record.settled_at or time - record.settled_at < 0.15 then
					record.transfer_frames = 2
				end
			end
			return false
		end
		if record.transfer_frames == 4 then
			for _, body in ipairs(record.dynamic_bodies) do
				body:set_dynamic()
			end
			record.dynamic_bodies = nil
		end
		if record.transfer_frames == 4 or record.transfer_frames == 5 then
			for index = 0, preview:num_bodies() - 1 do
				local source, target = preview:body(index), native:body(index)
				target:set_velocity(source:velocity())
				target:set_angular_velocity(source:angular_velocity())
			end
			return false
		end
		record.transfer_frames = nil
	end
	if mvector3.distance(preview:position(), native:position()) < 20 then
		return true
	end
	record.transfer_frames = 0
	record.follow_until_settled = true
	return false
end

local function native_removed(record)
	local native = exact_native(record)
	return native ~= nil and not alive(native)
end

local function retire(record, reason)
	if not record.secure_confirmed then
		get_runtime():retire_prediction_for_unit(prediction_unit(record), reason)
	end
	delete_preview(record)
end

local function secure_visual(record)
	record.secure_pending = true
	if alive(record.unit) then
		local interaction = record.unit:interaction()
		if interaction then
			interaction:set_active(false, false)
		end
		stop_collision_tracking(record)
	end
	if alive(record.native) then
		restore_bodies(record)
		record.native:set_visible(false)
		if record.native:interaction() then
			record.native:interaction():set_active(false, false)
		end
	end
end

local function confirm_secure(record)
	if record.secure_confirmed then
		return
	end
	secure_visual(record)
	get_runtime():retire_prediction_for_unit(prediction_unit(record), "native_secured")
	record.secure_confirmed = true
end

function M:native_secured(unit)
	self.secured[unit] = true
	self.captured[unit], self.watched[unit] = nil, nil
	for _, list in ipairs({ self.pending, self.awaiting_prediction }) do
		for index = #list, 1, -1 do
			local record = list[index]
			if exact_native(record) == unit then
				if list == self.pending then
					confirm_secure(record)
				else
					retire(record, "native_secured")
					table.remove(list, index)
				end
			end
		end
	end
end

function M:is_suppressed(unit)
	if self.secured[unit] or self.captured[unit] then
		return true
	end
	for _, record in ipairs(self.pending) do
		if
			record.secure_pending
			and (record.unit == unit or exact_native(record) == unit or prediction_unit(record) == unit)
		then
			return true
		end
	end
	return false
end

function M:has_suppressed_targets()
	if next(self.captured) then
		return true
	end
	for unit in pairs(self.secured) do
		if alive(unit) then
			return true
		end
	end
	for _, record in ipairs(self.pending) do
		if record.secure_pending then
			return true
		end
	end
	return false
end

function M:watch(unit, carry_id, token)
	if alive(unit) and carry_id and Network:is_client() and not self.secured[unit] then
		self.watched[unit] = { carry_id = carry_id, token = token, expires_at = now() + self.TIMEOUT }
	end
end

function M:capture_native(unit, time)
	if not alive(unit) or retained.is_suppressed(unit) or self.secured[unit] or self.captured[unit] then
		return false
	end
	local interaction = unit:interaction()
	self.captured[unit] = {
		expires_at = time + self.CAPTURE_TIMEOUT,
		interaction_active = interaction and interaction:active(),
	}
	self.watched[unit] = nil
	if interaction then
		interaction:set_active(false, false)
	end
	get_runtime():clear_local_detection(unit)
	return true
end

local function release_native(unit, state)
	if alive(unit) and not retained.is_suppressed(unit) then
		local interaction = unit:interaction()
		if interaction and state.interaction_active ~= nil then
			interaction:set_active(state.interaction_active, false)
		end
	end
end

local function capture_preview(self, record, time)
	if
		record.secure_pending
		or not alive(record.unit)
		or not secure_areas.contains(record.unit:position(), record.carry_id)
	then
		return false
	end

	record.secure_contact = secure_areas.contact(record.unit:position(), record.carry_id)
	secure_visual(record)
	record.expires_at = time + self.CAPTURE_TIMEOUT
	get_runtime():clear_local_detection(record.unit)
	if alive(record.native) then
		get_runtime():clear_local_detection(record.native)
	end
	return true
end

local function update_captures(self, time)
	for unit in pairs(self.secured) do
		if not alive(unit) then
			self.secured[unit] = nil
		end
	end
	for index = #self.pending, 1, -1 do
		capture_preview(self, self.pending[index], time)
	end
	for unit, watch in pairs(self.watched) do
		if not alive(unit) or time >= watch.expires_at then
			self.watched[unit] = nil
		elseif
			secure_areas.contains(unit:position(), watch.carry_id, unit:carry_data())
			and self:capture_native(unit, time)
		then
			local capture = self.captured[unit]
			capture.secure_contact = secure_areas.contact(unit:position(), watch.carry_id, unit:carry_data())
			capture.token = watch.token
		end
	end
	for unit, state in pairs(self.captured) do
		if state.secure_contact and not state.secure_request then
			state.secure_request = secure:report(state.token, state.secure_contact, unit)
		end
		local status = state.secure_request and state.secure_request.status
		local waiting = state.secure_request and status == nil
		if status == 1 then
			self:native_secured(unit)
		elseif not alive(unit) or time >= state.expires_at and not waiting or status == 0 then
			release_native(unit, state)
			self.captured[unit] = nil
		end
	end
end

function M:update(time)
	secure:update(time)
	update_captures(self, time)
	for index = #self.pending, 1, -1 do
		local record = self.pending[index]
		if record.secure_contact and not record.secure_request then
			record.secure_request =
				secure:report(record.native_key, record.secure_contact, record.native or record.unit)
		end
		local status = record.secure_request and record.secure_request.status
		if status == 1 then
			local native = exact_native(record)
			if alive(native) then
				self.secured[native] = true
				native:set_visible(false)
				local interaction = native:interaction()
				if interaction then
					interaction:set_active(false, false)
				end
			end
			confirm_secure(record)
		elseif status == 0 then
			record.expires_at = time
		end
		if not record.native and status ~= 1 then
			bind_native(record)
		end
		local runtime = get_runtime()
		local abandoned = record.prediction
			and not record.prediction.decision
			and not runtime:prediction_for_unit(prediction_unit(record))
		local removed = status == 1 or native_removed(record)
		if not removed and self.secured[exact_native(record)] then
			confirm_secure(record)
		end
		local waiting = record.secure_request and status == nil
		local expired = not alive(record.unit)
			or not record.secure_confirmed and (time >= record.expires_at and not waiting or abandoned)
		local finished = not removed
			and not expired
			and not record.secure_pending
			and record.native
			and finish_handoff(record, time)
		if removed then
			retire(record, status == 1 and "secure_ack" or "native_removed")
			table.remove(self.pending, index)
		elseif expired or finished then
			local pending_prediction = record.prediction and runtime:prediction_for_unit(prediction_unit(record))
			if expired and pending_prediction then
				if record.prediction.decision then
					runtime:retire_prediction_for_unit(prediction_unit(record), "native_drop_timeout")
				else
					runtime:cancel_prediction_for_unit(prediction_unit(record), "native_drop_timeout")
				end
			end
			local keep_prediction = finished and pending_prediction
			if finished then
				self:watch(record.native, record.carry_id, record.native_key)
			end
			restore_native(record)
			delete_preview(record, keep_prediction)
			if keep_prediction then
				record.expires_at = time + self.TIMEOUT
				self.awaiting_prediction[#self.awaiting_prediction + 1] = record
			end
			table.remove(self.pending, index)
		end
	end
	for index = #self.awaiting_prediction, 1, -1 do
		local record = self.awaiting_prediction[index]
		local runtime = get_runtime()
		if time >= record.expires_at then
			runtime:retire_prediction_for_unit(prediction_unit(record), "native_binding_timeout")
		end
		if time >= record.expires_at or not runtime:prediction_for_unit(prediction_unit(record)) then
			if not (self.captured[record.native] or self.secured[record.native]) then
				restore_native(record)
			end
			delete_preview(record)
			table.remove(self.awaiting_prediction, index)
		end
	end
end

function M:reset()
	secure:reset()
	for index = #self.pending, 1, -1 do
		if self.pending[index].prediction then
			get_runtime():cancel_prediction_for_unit(prediction_unit(self.pending[index]), "session_reset")
		end
		restore_native(self.pending[index])
		delete_preview(self.pending[index])
		self.pending[index] = nil
	end
	for index = #self.awaiting_prediction, 1, -1 do
		get_runtime():cancel_prediction_for_unit(prediction_unit(self.awaiting_prediction[index]), "session_reset")
		restore_native(self.awaiting_prediction[index])
		delete_preview(self.awaiting_prediction[index])
		self.awaiting_prediction[index] = nil
	end
	for unit, state in pairs(self.captured) do
		release_native(unit, state)
	end
	self.captured = setmetatable({}, { __mode = "k" })
	self.watched = setmetatable({}, { __mode = "k" })
	self.secured = setmetatable({}, { __mode = "k" })
	secure_areas.reset()
end

return M
