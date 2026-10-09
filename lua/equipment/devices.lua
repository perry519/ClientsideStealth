local control, proxy, restoring_call = ...
local M = {}

function M.spy_camera_interacted(unit)
	if Network:is_client() and control.allows_new_work("equipment") and alive(unit) and unit:id() ~= -1 then
		unit:set_visible(false)
		local access = unit:base()._interaction_unit
		if alive(access) then
			access:set_visible(false)
			access:interaction():set_active(false, false)
		end
	end
end

local function current_session()
	return managers.network:session()
end

local interacting, native_alive = proxy.interacting, proxy.native_alive

local function hide_preview(record)
	if alive(record.dummy) then
		local interaction = record.dummy:interaction()
		if interaction then
			interaction:set_active(false, false)
		end
		World:delete_unit(record.dummy)
	end
	record.dummy = nil
end

local function ready(state)
	return not state.closed and state.session == current_session() and Network:is_client()
end

local function apply(record)
	local state = record.device
	if not state.has_pending or state.sent or not ready(state) or not native_alive(state) then
		return
	end
	local base = state.native:base()
	if record.kind == "ecm_jammer" then
		if base:feedback_active() then
			state.native:interaction():remove_interact()
			state.sent = true
			return
		end
		base:set_feedback_active()
		state.native:interaction():remove_interact()
	elseif record.kind == "trip_mine" then
		if base._activate_timer then
			base:_set_armed(state.desired_armed)
		else
			base:set_armed(state.desired_armed)
		end
	end
	state.sent = true
end

function M:spawn(record, upgrade_level)
	if record.kind == "spy_camera" then
		local interaction = record.dummy:interaction()
		if interaction then
			interaction:set_active(false, false)
		end
		record.device = { session = record.session }
		return true
	end
	local dummy = record.dummy
	local unit
	if record.kind == "trip_mine" then
		local name = Idstring("units/clientsidestealth/equipment/trip_mine")
		local player_manager = managers.player
		local send_message = player_manager.send_message
		player_manager.send_message = function(self, message, ...)
			local _, placed_unit = ...
			if
				message == "trip_mine_placed"
				and alive(placed_unit)
				and placed_unit.name
				and placed_unit:name() == name
			then
				return
			end
			return send_message(self, message, ...)
		end
		unit = restoring_call(function()
			player_manager.send_message = send_message
		end, proxy.spawn, record, "Device interaction unavailable:")
	else
		unit = proxy.spawn(record, "Device interaction unavailable:")
	end
	if not unit then
		return false
	end
	local base = unit:base()
	local state = { session = record.session }
	record.device = state
	record.dummy = unit
	if record.kind == "ecm_jammer" then
		base:setup(upgrade_level or 1, nil)
		base:set_owner(managers.player:player_unit())
		base:set_active(true)
		base.set_feedback_active = function(self)
			if
				not ready(state)
				or state.expired
				or state.has_pending
				or not control.allows_new_work("equipment") and not interacting(record)
			then
				return
			end
			state.has_pending = true
			self:_set_feedback_active(true)
			if state.native then
				apply(record)
			end
		end
	elseif record.kind == "trip_mine" then
		base:setup(upgrade_level or false)
		base._activate_timer = 3
		base.set_armed = function(self, armed)
			if
				not ready(state)
				or state.expired
				or not control.allows_new_work("equipment") and not interacting(record)
			then
				return
			end
			state.has_pending = true
			state.desired_armed = armed
			self:_set_armed(armed)
			self._startup_armed = armed
			if state.native then
				apply(record)
			end
		end
	end
	proxy.replace_dummy(unit, dummy)
	return true
end

function M:arrive(record, unit)
	local state = record.device
	if state.closed or state.native or state.session ~= current_session() or unit:id() == -1 then
		return false
	end
	state.native, state.native_id = unit, unit:id()
	if record.kind == "ecm_jammer" and alive(record.dummy) then
		local base = record.dummy:base()
		if base._jam_sound_event then
			base._jam_sound_event:stop()
			base._jam_sound_event = nil
		end
	end
	apply(record)
	if
		record.kind == "trip_mine"
		and alive(record.dummy)
		and unit:base()._activate_timer
		and not interacting(record)
	then
		record.dummy:set_visible(false)
		record.dummy:interaction():set_active(false, false)
		state.waiting_activation = true
		return true
	end
	if not state.has_pending and interacting(record) then
		local interaction = unit:interaction()
		state.hidden = { visible = unit:visible(), active = interaction:active(), tweak = interaction.tweak_data }
		unit:set_visible(false)
		interaction:set_active(false, false)
		return true
	end
	return false
end

function M:update(record, now)
	local state = record.device
	if state.native then
		if state.waiting_activation then
			return not native_alive(state)
				or not state.native:base()._activate_timer
				or now >= record.expires_at
				or not control.allows_new_work("equipment")
		end
		return not native_alive(state) or not interacting(record) or now >= record.expires_at
	end
	if
		not alive(record.dummy)
		or now >= record.expires_at
		or not control.allows_new_work("equipment") and not interacting(record)
	then
		state.expired = true
		hide_preview(record)
		return not state.has_pending
	end
	return false
end

function M:destroy(record)
	local state = record.device
	if not state then
		return
	end
	state.closed = true
	hide_preview(record)
	if state.hidden and native_alive(state) then
		local unit = state.native
		unit:set_visible(state.hidden.visible)
		local interaction = unit:interaction()
		if interaction.tweak_data == state.hidden.tweak and not (state.sent and record.kind ~= "trip_mine") then
			interaction:set_active(state.hidden.active, false)
		end
	end
	record.device = nil
end

return M
