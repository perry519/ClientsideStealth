local Codec, Rpc, Channel = ...
local unpack_values = unpack or table.unpack
local A = { channel = Channel }
function A.session()
	return managers and managers.network and managers.network:session()
end
function A.is_server()
	return Network ~= nil and Network:is_server()
end
function A.local_id()
	local session = A.session()
	local peer = session and session.local_peer and session:local_peer()
	return peer and peer:id() or nil
end
local function verified_lua_peer(id)
	local session = A.session()
	if not session then
		return false, "session_not_ready"
	end
	local peer = session:peers()[id]
	if not peer then
		return false, "peer_not_ready"
	end
	if not peer:ip_verified() then
		return false, "peer_unverified"
	end
	return true
end
function A.control(id, body)
	local ready, reason = verified_lua_peer(id)
	if not ready then
		return false, reason
	end
	LuaNetworking:SendToPeer(id, "cst_rpc_v1_cap", body)
	return true
end
function A.handshake(peer, name, attempt, session, mine, theirs)
	peer:send(name, 1, attempt, session, mine, theirs)
end
A.rpc = { decode = Rpc.decode, schema = Rpc.SCHEMA }

function A.rpc.send(id, peer, channel, record)
	local ready, reason = verified_lua_peer(id)
	if not ready then
		return false, reason
	end
	local name, args = Rpc.encode(channel, record)
	if not name or not peer then
		return false, "invalid_rpc_record"
	end
	peer:send(name, unpack_values(args, 1, args.n or #args))
	return true
end
A.lua = {}
local PEER = { [Channel.peer] = true, [Channel.peer_relay] = true }
function A.lua.send(id, _, channel, record)
	local ready, reason = verified_lua_peer(id)
	if not ready then
		return false, reason
	end
	local encode = channel == Channel.report and Codec.encode_report
		or channel == Channel.state and Codec.encode_state
		or channel == Channel.prediction and Codec.encode_prediction
		or channel == Channel.camera_hud and Codec.encode_camera_hud
		or PEER[channel] and Codec.encode_peer
		or channel == Channel.peer_receipt and Codec.encode_peer_receipt
	local body
	if encode then
		body = encode(record)
	elseif channel == Channel.resync and record == "" then
		body = "1"
	elseif type(record) == "table" then
		body = table.concat(record, "|")
	else
		body = tostring(record)
	end
	if not body then
		return false, "invalid_lua_record"
	end
	LuaNetworking:SendToPeer(id, channel, body)
	return true
end
function A.lua.decode(channel, body)
	local decode = channel == Channel.report and Codec.decode_report
		or channel == Channel.state and Codec.decode_state
		or channel == Channel.prediction and Codec.decode_prediction
		or channel == Channel.camera_hud and Codec.decode_camera_hud
		or PEER[channel] and Codec.decode_peer
		or channel == Channel.peer_receipt and Codec.decode_peer_receipt
	local record, reason
	if decode then
		record, reason = decode(body)
	elseif channel == Channel.ready then
		if type(body) == "string" and body:match("^%d+$") and tostring(tonumber(body)) == body then
			record = tonumber(body)
		end
		reason = "invalid_ready"
	elseif channel == Channel.bag then
		record = Codec.parse_fields(body, Codec.MAX_MESSAGE_BYTES)
	elseif channel == Channel.hello and type(body) == "string" then
		record = body
	elseif channel == Channel.resync and body == "1" then
		record = ""
	end
	if record == nil then
		return nil, reason or "invalid_lua_record"
	end
	return channel, record
end
return A
