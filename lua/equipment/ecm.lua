local get_runtime, control = ...
local M = {}

local MAX_SENT = 16

local MAX_TRIM = 1

local function game_time()
	return TimerManager:game():time()
end

local function duration(upgrade)
	local base = tweak_data.upgrades.ecm_jammer_base_battery_life
	local multiplier = ECMJammerBase.battery_life_multiplier[upgrade]
	return base and multiplier and base * multiplier
end

local function ended(record)
	local unit = record.unit
	if game_time() >= record.deadline or unit and not alive(unit) then
		return true
	end
	local base = unit and unit:base()
	return base and base._battery_empty or false
end

function M:reset()
	self.pending = nil

	self.sent = {}
end

function M:busy_for_pause()
	return self.pending ~= nil
end

function M:update()
	if self.pending and ended(self.pending) then
		self.pending = nil
	end
end

function M:peer_lost(id)
	if id == get_runtime().host_peer_id then
		self:reset()
	end
end

function M.player_destroyed()
	M:reset()
end

function M:request_sent(upgrade)
	local runtime = get_runtime()
	local full = duration(upgrade)
	local record = full
			and not _G.IS_VR
			and control.allows_new_work("equipment")
			and runtime:is_active()
			and runtime:is_peer_capable(runtime.host_peer_id)
			and managers.player:has_category_upgrade("ecm_jammer", "affects_cameras")
			and { deadline = game_time() + full }
		or false
	self.sent[#self.sent + 1] = record
	if #self.sent > MAX_SENT then
		table.remove(self.sent, 1)
	end
	if record then
		self.pending = record
	end
end

function M:request_placed(unit)
	if not alive(unit) then
		return self:request_failed()
	end
	local record = table.remove(self.sent, 1)
	if record then
		record.unit = unit
	end
end

function M:request_failed()
	local record = table.remove(self.sent, 1)
	if record and record == self.pending then
		self.pending = nil
	end
end

function M:camera_jammed()
	if not self.pending or not get_runtime():is_active() then
		return false
	end
	if ended(self.pending) then
		self.pending = nil
		return false
	end
	return true
end

function M.trim_battery(base)
	local runtime = get_runtime()
	local peer_id = base._owner_id
	if
		not Network:is_server()
		or not peer_id
		or peer_id == runtime.local_peer_id
		or not runtime:is_active()
		or not runtime:is_peer_capable(peer_id)
		or not control.allows_new_work("equipment", peer_id)
		or not alive(base._owner)
		or not base._owner:base():upgrade_value("ecm_jammer", "affects_cameras")
	then
		return
	end
	local session = managers.network:session()
	local peer = session and session:peer(peer_id)
	if not peer or peer.is_vr and peer:is_vr() then
		return
	end
	local qos = peer:qos()
	local ping = qos and qos.ping
	if type(ping) == "number" and ping > 0 and type(base._battery_life) == "number" then
		base._battery_life = math.max(0, base._battery_life - math.min(ping / 2000, MAX_TRIM))
	end
end

M:reset()
return M
