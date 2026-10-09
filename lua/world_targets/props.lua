local world_target, get_runtime, Records = ...
local M = {}

local function last_interactor(unit)
	local interaction = unit:interaction()
	local peer = interaction and interaction._cst_prop_peer
	local session = peer and managers.network:session()
	return session and session:peer(peer:id()) == peer and peer:unit() or nil
end

function M.interacted(unit, player)
	local source = world_target.responsible_unit(player)
	local peer_id = world_target.peer_id(source)
	local session = peer_id and managers.network:session()
	local peer = session and session:peer(peer_id)
	local interaction = alive(unit) and unit:interaction()
	if interaction and peer then
		interaction._cst_prop_peer = peer
		M.sync(unit, source, true)
	end
end

function M.sequence_attention(env)
	local source = world_target.responsible_unit(env.src_unit)
	if not world_target.peer_id(source) then
		source = world_target.responsible_unit(env.params and env.params.unit)
	end
	M.sync(env.dest_unit, source)
end

function M.sync(unit, source_unit, interaction_completed)
	local id = alive(unit) and unit:id()
	local handler = id and id > 0 and unit:attention()
	if not handler or unit:brain() then
		return
	end
	local runtime = get_runtime()
	local target = runtime:target_for_unit(unit)
	if target and target.kind ~= "prop" then
		return
	end
	source_unit = world_target.responsible_unit(source_unit)
	if not world_target.peer_id(source_unit) then
		source_unit = last_interactor(unit)
	end
	local peer_id = world_target.peer_id(source_unit)
	local config = world_target.config(unit)
	local signature = config and Records.prediction_config_signature(config)
	local same_config = signature == handler._cst_prop_signature
	if
		same_config
		and (not config or target and (not interaction_completed or handler._cst_prop_source_unit == source_unit))
	then
		return
	end
	handler._cst_prop_signature = signature
	handler._cst_prop_source_unit = source_unit
	local session = managers and managers.network and managers.network:session()
	if session then
		session._cst_prop_revisions = session._cst_prop_revisions or {}
		local revisions = session._cst_prop_revisions
		revisions[id] = (revisions[id] or 0) + 1
		handler._cst_prop_revision = revisions[id]
	else
		handler._cst_prop_revision = (handler._cst_prop_revision or 0) + 1
	end
	runtime:cancel_prediction_for_unit(unit, "prop_attention_changed")
	if same_config and target then
		if Network:is_server() then
			runtime:forget_prediction_proofs(target.kind, target.id, unit)
		end
	else
		world_target.unregister_unit(unit)
	end
	if not config then
		return
	end
	local spec = {
		kind = "prop",
		id = id,
		unit = unit,
		cause = "prop_attention",
		native_key = "prop:" .. id .. ":" .. handler._cst_prop_revision .. ":" .. signature,
		source_unit = source_unit,
		owner_peer_id = peer_id,
		config = config,
	}
	if Network:is_server() then
		world_target.register("prop", id, unit, peer_id)
		if peer_id then
			runtime:confirm_prediction(spec)
		end
	else
		if peer_id then
			runtime:predict_target(spec)
		end
		world_target.register("prop", id, unit)
	end
end

function M.attention_changed(handler)
	if handler._cst_prop_signature then
		local config = world_target.config(handler._unit)
		if not config then
			M.sync(handler._unit)
		elseif Records.prediction_config_signature(config) ~= handler._cst_prop_signature then
			get_runtime():cancel_prediction_for_unit(handler._unit, "prop_attention_changed")
			world_target.unregister_unit(handler._unit)
		end
	end
end

function M.destroy(handler)
	if handler._cst_prop_signature then
		get_runtime():cancel_prediction_for_unit(handler._unit, "removed")
		world_target.unregister_unit(handler._unit)
	end
end

return M
