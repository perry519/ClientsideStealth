local get_runtime, adapters, settings, control, control_host, control_client, transport, target_kinds = ...
local features = {}
local FEATURES = settings.FEATURES
local COUNT = #FEATURES
local NONE = string.rep("0", COUNT)
local INDEX = {}
for index, name in ipairs(FEATURES) do
	INDEX[name] = index
end

local IS_KIND = target_kinds

local SOURCES = { "player", "bag", "corpse", "hostage", "vehicle", "drill", "prop" }

local LOCAL = { equipment = true }

local NEEDS_SOURCE = { npc = true, intimidation = true, dart = true, camera_loop = true }

local PARENT = { bag_secure = "bag_handling" }

local BUSY = { bag_handling = "bag", bag_secure = "bag", equipment = "equipment" }
local RETRY = 1
local MASTER_RETRY = 5
local STATUS_INTERVAL = 0.25

local state
local listeners = {}
local roster

function features.use_roster(peers)
	roster = peers
end

local function has(mask, name)
	local index = assert(INDEX[name], "ClientsideStealth: unknown feature " .. tostring(name))
	return mask:sub(index, index) == "1"
end

local function grants_beyond(mask, asked, kept)
	for index = 1, COUNT do
		if mask:sub(index, index) == "1" and asked:sub(index, index) ~= "1" and kept:sub(index, index) ~= "1" then
			return true
		end
	end
	return false
end

local function delta(old, new)
	local on, off = {}, {}
	for index, name in ipairs(FEATURES) do
		local was, is = old:sub(index, index) == "1", new:sub(index, index) == "1"
		if is and not was then
			on[name] = true
		elseif was and not is then
			off[name] = true
		end
	end
	return on, off
end

local function kinds_in(set)
	local kinds = {}
	for kind in pairs(IS_KIND) do
		if set[kind] then
			kinds[kind] = true
		end
	end
	return next(kinds) and kinds or nil
end

local function any_kind(mask)
	for kind in pairs(IS_KIND) do
		if has(mask, kind) then
			return true
		end
	end
	return false
end

local function valid_mask(mask)
	return type(mask) == "string" and #mask == COUNT and not mask:find("[^01]")
end

local function dependent_mask(get)
	local source = false
	for _, kind in ipairs(SOURCES) do
		source = source or get(kind)
	end
	local chars = {}
	for index, name in ipairs(FEATURES) do
		local on = name == "detection" and source or name ~= "detection" and get(name)
		if NEEDS_SOURCE[name] then
			on = on and source
		end
		if PARENT[name] then
			on = on and get(PARENT[name])
		end
		chars[index] = on and "1" or "0"
	end
	return table.concat(chars)
end

function features.requested()
	return settings.get("enabled") and dependent_mask(settings.get) or NONE
end

local function host_permitted()
	return dependent_mask(settings.get)
end

local function negotiated(requested, permitted)
	return dependent_mask(function(name)
		return has(requested, name) and has(permitted, name)
	end)
end

local function consistent(mask)
	return dependent_mask(function(name)
		return has(mask, name)
	end) == mask
end

function features.reset()
	state = {
		seq = 0,

		sent = nil,
		holding = nil,
		acked = nil,
		drain = nil,

		permitted = nil,
		pseq = 0,

		peers = {},
		deferred = {},
		pushes = {},
		push_names = {},
		master_retry = 0,
		master_failed = nil,
		next_status = 0,
		signature = nil,
	}
end
features.reset()

function features.peer_lost(peer_id)
	state.peers[peer_id], state.deferred[peer_id], state.pushes[peer_id] = nil, nil, nil
end

local function is_host()
	return get_runtime():is_host()
end

local function host_ready(runtime)
	return runtime:session() ~= nil
		and (
			runtime:is_peer_capable(runtime.host_peer_id)
			or control_client.has_seen_host_control()
			or transport:mode(runtime.host_peer_id) ~= nil
		)
end

local function switch_hold(runtime)
	return not is_host()
		and runtime:is_peer_capable(runtime.host_peer_id)
		and transport:switch_wanted(runtime.host_peer_id)
end

function features.switch_ready(peer_id)
	local runtime = get_runtime()
	if is_host() or peer_id ~= runtime.host_peer_id or not runtime:is_peer_capable(runtime.host_peer_id) then
		return true
	end
	local acked = state.acked
	return state.holding == true
		and not state.sent
		and not state.drain
		and acked ~= nil
		and acked.effective == NONE
		and not adapters.bag.awaits_host_records()
end

local function local_mask()
	if is_host() then
		return state.permitted or host_permitted()
	end
	return state.acked and state.acked.effective or host_ready(get_runtime()) and NONE or features.requested()
end

function features.allows(name)
	if LOCAL[name] and not is_host() and not host_ready(get_runtime()) then
		return has(features.requested(), name)
	end
	return has(local_mask(), name)
end

function features.effective(peer_id)
	if not is_host() then
		return nil
	end
	if peer_id == get_runtime().local_peer_id then
		return state.permitted or host_permitted()
	end
	local record = state.peers[peer_id]
	return record and record.effective or nil
end

function features.allows_peer(peer_id, name)
	if not is_host() then
		return true
	end
	local record = state.peers[peer_id]
	return record ~= nil and has(record.effective, name)
end

function features.allows_detection()
	return any_kind(local_mask()) or state.drain ~= nil
end

function features.is_kind(kind)
	return IS_KIND[kind] == true
end

local function host_pending(name)
	local permitted = host_permitted()
	if state.permitted and has(state.permitted, name) ~= has(permitted, name) then
		return true
	end
	if state.push_names[name] and next(state.pushes) then
		return true
	end
	for peer_id in pairs(state.deferred) do
		local record = state.peers[peer_id]
		if record and has(record.effective, name) ~= has(negotiated(record.requested, permitted), name) then
			return true
		end
	end
	return false
end

function features.connection()
	local runtime = get_runtime()
	local session = runtime:session()
	local rpc, lua = 0, 0
	for id in pairs(session and session:peers() or {}) do
		if id ~= runtime.local_peer_id then
			local mode = transport:mode(id)
			rpc = rpc + (mode == "rpc" and 1 or 0)
			lua = lua + (mode == "lua" and 1 or 0)
		end
	end
	if transport.restart_required then
		return "cst_connection_restart", 0, rpc + lua
	end
	local key = rpc > 0 and lua > 0 and "cst_connections_rpc_lua"
		or rpc > 0 and "cst_connections_rpc"
		or lua > 0 and "cst_connections_lua"
		or "cst_connections_none"
	return key, rpc, lua
end

function features.lobby()
	local runtime = get_runtime()
	local session = runtime:session()
	if not session then
		return nil
	end
	local rows = {}
	for id, peer in pairs(session:peers()) do
		if id ~= runtime.local_peer_id then
			local row = { id = id, name = peer:name(), mode = transport:mode(id), host = id == runtime.host_peer_id }
			local record = is_host() and state.peers[id] or nil
			local effective = record and record.effective or not is_host() and roster and roster.effective(id)
			local permitted = is_host() and (state.permitted or host_permitted())
				or roster and roster.effective(runtime.host_peer_id)
			if effective and permitted then
				row.using, row.allowed, row.off, row.blocked = 0, 0, {}, {}
				for _, name in ipairs(FEATURES) do
					local allowed, used = row.host or has(permitted, name), has(effective, name)
					row.allowed, row.using = row.allowed + (allowed and 1 or 0), row.using + (used and 1 or 0)
					if allowed and not used then
						row.off[#row.off + 1] = name
					elseif not allowed and record and has(record.requested, name) then
						row.blocked[#row.blocked + 1] = name
					end
				end
			end
			rows[#rows + 1] = row
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

function features.status(name)
	if name == "lua_networking" then
		if transport:settling() then
			return "pending", "cst_reason_switching"
		end
		return settings.get(name) and "on" or "off"
	end
	local runtime = get_runtime()
	local saved = name == "detection" and has(host_permitted(), name) or name ~= "detection" and settings.get(name)
	local wanted = name == "enabled" and saved or name ~= "enabled" and has(features.requested(), name)
	if runtime:session() then
		if is_host() then
			if
				name == "enabled" and (runtime.enabled ~= false) ~= saved
				or name ~= "enabled" and host_pending(name)
			then
				return "pending", "cst_reason_applying"
			end
		elseif host_ready(runtime) then
			local acked = state.acked
			if state.holding and wanted then
				return "pending", "cst_reason_switching"
			elseif name == "enabled" then
				if saved and runtime.enabled == false and not control.is_loud_latched() then
					return "paused", "cst_reason_paused"
				elseif state.sent or state.drain or not acked or not saved and acked.effective ~= NONE then
					return "pending", "cst_reason_pending"
				end
			elseif not acked or state.drain and state.drain.names[name] then
				return "pending", "cst_reason_pending"
			else
				local requested = features.requested()
				if has(requested, name) ~= has(acked.effective, name) then
					if not has(requested, name) or has(negotiated(requested, state.permitted), name) then
						return "pending", "cst_reason_pending"
					end
					return "unavailable",
						has(state.permitted, name) and "cst_reason_dependency" or "cst_reason_host_disabled"
				end
			end
		elseif wanted and name ~= "enabled" and not LOCAL[name] then
			return "unavailable", "cst_reason_no_host"
		end
	end
	if saved and NEEDS_SOURCE[name] and not has(host_permitted(), name) then
		return "unavailable", "cst_reason_no_source"
	end
	return saved and "on" or "off"
end

function features.on_status_changed(fn)
	listeners[#listeners + 1] = fn
end

local function notify_status(now)
	if not listeners[1] or now < state.next_status then
		return
	end
	state.next_status = now + STATUS_INTERVAL
	local parts = { (features.status("enabled")), (features.status("lua_networking")) }
	for _, name in ipairs(FEATURES) do
		parts[#parts + 1] = features.status(name)
	end
	for _, row in ipairs(features.lobby() or {}) do
		local off, blocked = row.off and table.concat(row.off, "+"), row.blocked and table.concat(row.blocked, "+")
		parts[#parts + 1] = row.id
			.. ":"
			.. tostring(row.mode)
			.. ":"
			.. tostring(row.using)
			.. ":"
			.. tostring(row.allowed)
			.. ":"
			.. tostring(off)
			.. ":"
			.. tostring(blocked)
	end
	local signature = table.concat(parts, ",")
	if signature == state.signature then
		return
	end
	state.signature = signature
	for _, fn in ipairs(listeners) do
		fn()
	end
end

function features.set(name, value)
	local changed = settings.set(name, value)
	if changed and name == "lua_networking" then
		transport:prefer(value and "lua" or "rpc")
	elseif changed then
		state.master_retry, state.master_failed, state.next_status = 0, nil, 0
	end
	return changed
end

function features.press()
	local value = not settings.get("enabled")
	features.set("enabled", value)
	if not is_host() then
		control.status(value and "cst_status_client_requested" or "cst_status_client_pause_requested")
	end
end

local function send_request(runtime, now)
	local sent = state.sent
	if now < sent.retry then
		return
	end
	sent.retry = now + RETRY
	control.send(runtime.host_peer_id, control.CHANNEL, "d:" .. sent.seq .. ":" .. sent.mask .. ":" .. sent.pseq)
end

local function finish_drain(runtime)
	local drain = state.drain
	if not drain or runtime.enabled ~= false and not runtime:applied_snapshot_after(drain.floor) then
		return
	end
	if runtime.enabled ~= false and drain.kinds and runtime:owns_local_targets(drain.kinds) then
		return
	end
	state.drain = nil
	local effective = local_mask()
	if not any_kind(effective) then
		runtime:clear_local_views()
	end
	if drain.quiet then
		return
	end
	control.status(
		runtime.enabled == false and "cst_status_settings_saved_host_paused"
			or not settings.get("enabled") and effective ~= NONE and "cst_status_pause_pending_transactions"
			or effective == NONE and "cst_status_client_disabled"
			or "cst_status_settings_applied"
	)
end

local function update_client(runtime, now)
	finish_drain(runtime)
	if not host_ready(runtime) then
		return
	end
	if switch_hold(runtime) then
		state.holding = true
	elseif state.holding == true then
		state.holding = "release"
	end

	local desired = state.holding == true and NONE or features.requested()
	local current = local_mask()
	local chars = {}
	for index, name in ipairs(FEATURES) do
		local want = desired:sub(index, index)
		local keep = BUSY[name]
			and want ~= current:sub(index, index)
			and control.busy_for({ [BUSY[name]] = true }, true)
		chars[index] = keep and current:sub(index, index) or want
	end
	desired = table.concat(chars)
	local base = state.sent or state.acked
	if not base or base.mask ~= desired or base.pseq < state.pseq then
		state.seq = state.seq + 1
		state.sent = { seq = state.seq, mask = desired, pseq = state.pseq, retry = 0 }
	end
	if state.sent then
		send_request(runtime, now)
	end
end

local function apply_peer(runtime, peer_id, record)
	local target = negotiated(record.requested, state.permitted)
	if target == record.effective then
		state.deferred[peer_id] = nil
		return
	end
	local holds = adapters.bag.holds_peer(peer_id)
	local chars = {}
	for index, name in ipairs(FEATURES) do
		local was, want = record.effective:sub(index, index), target:sub(index, index)
		local wait = was ~= want
			and (
				holds and (name == "bag" or BUSY[name] == "bag")
				or was == "1" and IS_KIND[name] and runtime:hands_off_from(peer_id, { [name] = true })
			)
		chars[index] = wait and was or want
	end
	local applied = table.concat(chars)
	state.deferred[peer_id] = applied ~= target or nil
	if applied ~= record.effective then
		local on, off = delta(record.effective, applied)
		record.effective, record.floor, record.rev = applied, runtime.snapshot_seq, record.rev + 1
		local enabled, disabled = kinds_in(on), kinds_in(off)
		if enabled or disabled then
			runtime:apply_peer_preference(peer_id, enabled, disabled)
		end
	end
end

local function new_record()
	return { seq = 0, requested = NONE, effective = NONE, floor = 0, pseq = 0, rev = 0 }
end

local function update_permission()
	local permitted = host_permitted()
	if permitted == state.permitted then
		return
	end
	local previous = state.permitted
	if not previous then
		state.permitted = permitted
		return
	end
	local on, off = delta(previous, permitted)
	for name in pairs(on) do
		off[name] = true
	end
	state.permitted, state.pseq, state.push_names = permitted, state.pseq + 1, off
	for peer_id in pairs(state.peers) do
		state.pushes[peer_id], state.deferred[peer_id] = 0, true
	end
end

local function update_master(runtime, now)
	local desired = settings.get("enabled")

	if desired and control.is_preparing() and not control.is_loud() then
		control_host.set_enabled(true)
		return
	end
	if
		desired == (runtime.enabled ~= false)
		or now < state.master_retry
		or control_host.has_pending()
		or control.is_preparing()
		or desired and control.is_loud()
	then
		return
	end
	state.master_retry = now + MASTER_RETRY
	if not control_host.set_enabled(desired) and state.master_failed ~= desired then
		state.master_failed = desired
		control.status("cst_status_toggle_pending_transaction")
	end
end

local function update_host(runtime, now)
	update_permission()
	for peer_id in pairs(state.deferred) do
		local record = state.peers[peer_id]
		if record then
			apply_peer(runtime, peer_id, record)
		else
			state.deferred[peer_id] = nil
		end
	end
	for peer_id, retry in pairs(state.pushes) do
		if now >= retry then
			state.pushes[peer_id] = now + RETRY
			control.send(peer_id, control.CHANNEL, "d:p:" .. state.pseq .. ":" .. state.permitted)
		end
	end
	update_master(runtime, now)
end

function features.update(now)
	local runtime = get_runtime()
	if runtime:session() then
		if is_host() then
			update_host(runtime, now)
		else
			update_client(runtime, now)
		end
	end
	notify_status(now)
end

local function parse_number(text)
	local value = tonumber(text)
	return value and value >= 0 and value <= 1000000000 and value or nil
end

local function receive_push(sender, body)
	local runtime = get_runtime()
	local pseq, permitted = body:match("^d:p:(%d+):([01]+)$")
	pseq = parse_number(pseq)
	if sender ~= runtime.host_peer_id or not runtime:session() or not pseq or not valid_mask(permitted) then
		return false
	end
	if pseq > state.pseq then
		state.pseq, state.permitted = pseq, permitted
	end
	return true
end

function features.receive(sender, body)
	local runtime = get_runtime()
	local session = runtime:session()
	if type(body) ~= "string" or #body > 64 then
		return false
	end
	if not is_host() then
		return receive_push(sender, body)
	end
	local seq, mask, pseq = body:match("^d:(%d+):([01]+):(%d+)$")
	seq, pseq = parse_number(seq), parse_number(pseq)
	if
		not session
		or not session:peer(sender)
		or sender == runtime.local_peer_id
		or not seq
		or seq < 1
		or not pseq
		or not valid_mask(mask)
		or not consistent(mask)
		or not (runtime:is_peer_capable(sender) or control_host.knows_peer(sender) or transport:mode(sender) ~= nil)
	then
		return false
	end
	update_permission()
	local record = state.peers[sender]
	if record and (seq < record.seq or seq == record.seq and mask ~= record.requested) then
		return false
	end
	if not record and not runtime:is_peer_capable(sender) then
		control_host.peer_negotiated(sender)
	end
	if not record or seq > record.seq then
		record = record or new_record()
		record.requested, record.seq, record.pseq = mask, seq, pseq
		state.peers[sender] = record
		apply_peer(runtime, sender, record)
	end
	if record.pseq >= state.pseq then
		state.pushes[sender] = nil
	end
	if runtime.enabled ~= false and runtime:is_peer_capable(sender) then
		runtime:send_snapshot(sender)
	end
	control.send(
		sender,
		control.ACK,
		"d:" .. seq .. ":" .. record.effective .. ":" .. record.floor .. ":" .. state.permitted .. ":" .. record.rev
	)
	return true
end

function features.receive_ack(sender, body)
	local runtime = get_runtime()
	if type(body) ~= "string" or #body > 64 or is_host() then
		return false
	end
	local seq, effective, floor, permitted, rev = body:match("^d:(%d+):([01]+):(%d+):([01]+):(%d+)$")
	seq, floor, rev = parse_number(seq), parse_number(floor), parse_number(rev)
	local sent, acked = state.sent, state.acked
	local previous = local_mask()
	if
		sender ~= runtime.host_peer_id
		or not runtime:session()
		or not sent
		or sent.seq ~= seq
		or not floor
		or not rev
		or not valid_mask(effective)
		or not valid_mask(permitted)
		or acked and acked.seq == seq and rev <= acked.rev
		or grants_beyond(effective, sent.mask, previous)
	then
		return false
	end

	local quiet = acked == nil or state.holding ~= nil
	local on, off = delta(previous, effective)
	state.acked = { seq = seq, mask = sent.mask, pseq = sent.pseq, effective = effective, rev = rev }
	state.permitted = permitted

	if effective == negotiated(sent.mask, permitted) then
		state.sent = nil
		if state.holding == "release" then
			state.holding = nil
		end
	end
	local off_kinds = kinds_in(off)
	if off_kinds then
		runtime:cancel_predictions("detection_disabled", off_kinds)
	end
	local drain = state.drain
	if drain then
		for name in pairs(on) do
			drain.names[name] = nil
		end
		state.drain = next(drain.names) and drain or nil
	end

	if off_kinds and runtime:is_peer_capable(runtime.host_peer_id) then
		drain = state.drain or { names = {}, quiet = quiet }
		drain.floor = math.max(drain.floor or 0, floor)
		for name in pairs(off) do
			drain.names[name] = (IS_KIND[name] or name == "detection") or nil
		end
		state.drain = drain
	end
	if state.drain then
		state.drain.kinds = kinds_in(state.drain.names)
	end
	if not off_kinds and (next(on) or next(off)) and not quiet then
		control.status(
			runtime.enabled == false and "cst_status_settings_saved_host_paused"
				or kinds_in(on) and "cst_status_enabled_sync"
				or "cst_status_settings_applied"
		)
	end
	return true
end

return features
