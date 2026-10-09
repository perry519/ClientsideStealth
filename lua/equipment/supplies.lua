local control, get_runtime, Log, proxy = ...
local M = {}
local unsupported = {}
local previews = setmetatable({}, { __mode = "k" })
local kinds = {
	ammo_bag = {
		take = "take_ammo",
		rpc = "sync_ammo_bag_ammo_taken",
		sync = "sync_ammo_taken",
		amount = "_ammo_amount",
	},
	doctor_bag = { take = "take", rpc = "sync_doctor_bag_taken", sync = "sync_taken", amount = "_amount" },
	bodybags_bag = { take = "take_bodybag", rpc = "sync_unit_event_id_16", event = 1, amount = "_bodybag_amount" },
	first_aid_kit = { take = "take", rpc = "sync_unit_event_id_16", event = 2 },
	grenade_crate = {
		take = "take_grenade",
		rpc = "sync_unit_event_id_16",
		event = 1,
		amount = "_grenade_amount",
	},
}

local function session()
	return managers.network:session()
end

local function remove_uppers(record, unit)
	if record.kind == "first_aid_kit" and alive(unit) then
		FirstAidKitBase.Remove(unit:base())
	end
end

local interacting, native_alive = proxy.interacting, proxy.native_alive

local function hide_preview(record)
	local unit = record.dummy
	if alive(unit) then
		remove_uppers(record, unit)
		unit:interaction():set_active(false, false)
		World:delete_unit(unit)
	end
	record.dummy = nil
end

function M:destroy(record)
	local state = record.supply
	if not state then
		return
	end
	state.closed = true
	hide_preview(record)
	if native_alive(state) then
		local unit = state.native
		if state.hidden and (not unit:base()._empty or record.kind == "bodybags_bag") then
			unit:set_visible(state.visible)
		end
		if unit:base()._empty then
			remove_uppers(record, unit)
		elseif state.hidden then
			local interaction = unit:interaction()
			if interaction.tweak_data == state.tweak_data then
				interaction:set_active(state.active, false)
			end
		end
	end
	record.supply = nil
end

local function flush(record)
	local state = record.supply
	if state.closed or state.session ~= session() or not native_alive(state) then
		return
	end
	local queued = state.queued
	state.queued = {}
	local definition = kinds[record.kind]
	for _, amount in ipairs(queued) do
		local unit = state.native
		if definition.event then
			state.session:send_to_peers_synched(definition.rpc, unit, "base", definition.event)
			unit:base():sync_net_event(definition.event)
		else
			state.session:send_to_peers_synched(definition.rpc, unit, amount)
			unit:base()[definition.sync](unit:base(), amount)
		end
	end
	if state.native:base()._empty then
		remove_uppers(record, state.native)
	end
end

function M.proxy_send(network, rpc, unit, ...)
	local record = previews[unit]
	if not record then
		return false
	end
	local state = record.supply
	if not state or state.closed or state.session ~= network or network ~= session() then
		return true
	end
	local definition = kinds[record.kind]
	local amount, event = ...
	local valid = rpc == definition.rpc
	if valid and definition.event then
		valid = amount == "base" and event == definition.event
		amount = 1
	elseif valid then
		valid = type(amount) == "number" and amount > 0 and amount == amount and amount < math.huge
	end
	if not valid then
		unsupported[record.kind] = true
		state.unsupported = true
		Log.warn_once("Supply prediction unavailable:", record.kind, "unexpected_proxy_rpc:" .. tostring(rpc))
		return true
	end
	state.queued[#state.queued + 1] = amount
	if state.native then
		flush(record)
	end
	return true
end

function M:spawn(record, upgrade_level, bullet_storm_level)
	local definition = kinds[record.kind]
	if unsupported[record.kind] then
		return false
	end
	if record.kind == "grenade_crate" then
		local host = record.session:server_peer()
		if not host or not get_runtime():is_peer_capable(host:id()) then
			return false
		end
	end
	local dummy = record.dummy
	local unit = proxy.spawn(record, "Supply prediction unavailable:")
	if not unit then
		return false
	end
	local base = unit:base()
	local state = { session = record.session, queued = {} }
	record.supply = state
	record.dummy = unit
	previews[unit] = record
	base._set_empty = function(self)
		self._empty = true
		if definition.amount then
			self[definition.amount] = 0
		end
		remove_uppers(record, unit)
		unit:interaction():set_active(false, false)
		unit:set_visible(false)
	end
	local take = base[definition.take]
	base[definition.take] = function(self, player, ...)
		if
			state.closed
			or state.expired
			or state.unsupported
			or not control.allows_new_work("equipment") and not interacting(record)
			or state.session ~= session()
			or not Network:is_client()
			or player ~= managers.player:player_unit()
			or not alive(player)
			or self._empty
		then
			return false
		end
		if state.native then
			if not native_alive(state) or state.native:base()._empty then
				self:_set_empty()
				return false
			end
			if definition.amount then
				self[definition.amount] = state.native:base()[definition.amount]
			end
		end
		return take(self, player, ...)
	end
	base:setup(upgrade_level or 0, bullet_storm_level or 0)
	proxy.replace_dummy(unit, dummy)
	return true
end

function M:arrive(record, unit)
	local state = record.supply
	if state.native or state.closed or state.session ~= session() or unit:id() == -1 then
		return false
	end
	state.native = unit
	state.native_id = unit:id()
	flush(record)
	remove_uppers(record, record.dummy)
	if not unit:base()._empty and interacting(record) then
		state.hidden = true
		state.visible = unit:visible()
		local interaction = unit:interaction()
		state.active = interaction:active()
		state.tweak_data = interaction.tweak_data
		unit:set_visible(false)
		interaction:set_active(false, false)
		return true
	end
	return false
end

function M:update(record, now)
	local state = record.supply
	if state.native then
		return not native_alive(state)
			or state.native:base()._empty
			or not interacting(record)
			or now >= record.expires_at
	end
	if
		not alive(record.dummy)
		or now >= record.expires_at
		or not control.allows_new_work("equipment") and not interacting(record)
	then
		state.expired = true
		hide_preview(record)
		return #state.queued == 0
	end
	return false
end

function M.accepts_owner_setup(peer_id)
	return get_runtime():is_peer_capable(peer_id)
end

return M
