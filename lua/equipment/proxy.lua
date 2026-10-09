local Log = ...
local proxy = {}

function proxy.native_alive(state)
	return alive(state.native) and state.native:id() == state.native_id
end

function proxy.interacting(record)
	if not alive(record.dummy) then
		return false
	end
	local interaction = record.dummy:interaction()
	return interaction ~= nil and interaction._tweak_data_at_interact_start == interaction.tweak_data
end

function proxy.spawn(record, label)
	local name = Idstring("units/clientsidestealth/equipment/" .. record.kind)
	if not PackageManager:has(Idstring("unit"), name) then
		Log.warn_once(label, record.kind, "asset_not_loaded")
		return nil
	end
	local sync = PackageManager:unit_data(name):network_sync()
	if sync ~= "none" and sync ~= "client" then
		Log.warn_once(label, record.kind, "asset_network_mode")
		return nil
	end
	local unit = World:spawn_unit(name, record.dummy:position(), record.dummy:rotation())
	if not alive(unit) then
		Log.warn_once(label, record.kind, "spawn_failed")
		return nil
	end
	if unit:id() ~= -1 or not unit:base() or not unit:interaction() then
		World:delete_unit(unit)
		Log.warn_once(label, record.kind, "invalid_proxy")
		return nil
	end
	local base = unit:base()
	if base._validate_clbk_id then
		managers.enemy:remove_delayed_clbk(base._validate_clbk_id)
		base._validate_clbk_id = nil
	end
	return unit
end

function proxy.replace_dummy(unit, dummy)
	for index = 0, unit:num_bodies() - 1 do
		unit:body(index):set_enabled(false)
	end
	World:delete_unit(dummy)
end

return proxy
