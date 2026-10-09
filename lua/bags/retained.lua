local get_client, Unit, get_runtime, control, transport, peers = ...
local M = {}
M.held = {}
M.history = {}

function M.session()
	return managers.network and managers.network:session()
end

function M.target(unit)
	local runtime = get_runtime()
	return alive(unit) and runtime:target_identity_for_unit(unit) or nil
end

function M.peer_id(peer)
	return peer and peer.id and peer:id() or nil
end

function M.resolve(id, incarnation)
	local runtime = get_runtime()
	return runtime:target_identity("bag", id, incarnation)
end

local function record_key(record)
	return table.concat({ record.id, record.incarnation, record.generation, record.peer_id }, ":")
end

function M.remember(record, disposition)
	local previous = M.history[record.peer_id]
	if previous and previous.generation > record.generation then
		return
	end
	M.history[record.peer_id] = {
		key = record_key(record),
		generation = record.generation,
		disposition = disposition or "terminal",
		record = record,
	}
end

function M.remember_head(id, incarnation, generation, holder)
	local previous = M.history[holder]
	if not previous or generation > previous.generation then
		M.history[holder] = {
			key = table.concat({ id, incarnation, generation, holder }, ":"),
			generation = generation,
		}
	end
end

function M.retire(record, disposition)
	M.held[record.peer_id] = nil
	M.remember(record, disposition)
end

local CHANNEL = transport.channel.bag

function M.head(op, record)
	return { op, record.id, record.incarnation, record.generation, record.peer_id }
end

function M.send(peer, record)
	if not peer then
		return false
	end
	return transport:send(peer, CHANNEL, record)
end

function M.broadcast(record)
	local runtime = get_runtime()
	local current = M.session()
	for id in pairs(current and current:peers() or {}) do
		if runtime:is_peer_capable(id) then
			M.send(id, record)
		end
	end
end

function M.holds_peer(peer_id)
	return M.held[peer_id] ~= nil
end

function M.holding(unit)
	for _, record in pairs(M.held) do
		if record.unit == unit then
			return record
		end
	end
end

function M.is_suppressed(unit)
	return get_client():holds(unit) or M.holding(unit) ~= nil
end

function M.has_suppressed_targets()
	return get_client():holds_any() or next(M.held) ~= nil
end

local function is_bag_unit(unit)
	local data = Unit.carry(unit)
	local carry_tweak = data and tweak_data.carry[data._carry_id]
	local unit_name = carry_tweak and (carry_tweak.unit or "units/payday2/pickups/gen_pku_lootbag/gen_pku_lootbag")
	return unit_name ~= nil and unit:name() == Idstring(unit_name)
end

function M.unbagged(unit)
	local int = Unit.interaction(unit)
	return int ~= nil and int._remove_on_interact == true and Unit.carry(unit) ~= nil and not is_bag_unit(unit)
end

function M.preserve_pickup(unit, holder)
	local runtime = get_runtime()
	local int, bag = Unit.interaction(unit), M.target(unit)
	if
		not runtime:is_active()
		or not alive(unit)
		or not is_bag_unit(unit)
		or not int
		or int._remove_on_interact ~= true
		or not bag
		or bag.kind ~= "bag"
		or bag.eligible == false
	then
		return false
	end
	if M.is_suppressed(unit) then
		return true
	end
	if not control.allows_new_work("bag_handling", holder) then
		return false
	end
	if not Network:is_server() and not runtime:is_peer_capable(runtime.host_peer_id) then
		return false
	end
	local current = M.session()
	for id in pairs(current and current:peers() or {}) do
		if id ~= runtime.local_peer_id then
			if Network:is_server() or id == runtime.host_peer_id then
				if not runtime:is_peer_capable(id) then
					return false
				end
			elseif peers.membership(id) == nil then
				return false
			end
		end
	end
	return true
end

function M.reset()
	for _, record in pairs(M.held) do
		Unit.remove(record)
	end
	M.held, M.history = {}, {}
end

function M.enabled()
	return get_runtime().enabled ~= false
end

return M
