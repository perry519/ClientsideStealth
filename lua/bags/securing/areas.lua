local M = {}

local SECURE_OPERATIONS = { secure = true, secure_silent = true }
local MAX_LINK_DEPTH = 8

local function leads_to_secure(script, element, depth, seen)
	if seen[element] or depth > MAX_LINK_DEPTH then
		return false
	end
	seen[element] = true
	local values = element._values or {}
	if ElementCarry and element.on_executed == ElementCarry.on_executed and SECURE_OPERATIONS[values.operation] then
		return true
	end
	for _, link in ipairs(values.on_executed or {}) do
		local linked = script:element(link.id)
		if linked and leads_to_secure(script, linked, depth + 1, seen) then
			return true
		end
	end
	return false
end

local accepts = {
	loot = function(carry_id)
		local list = ElementAreaTrigger.carry_list or tweak_data.carry:get_carry_ids_lookup_for_area_trigger()
		return list[carry_id]
	end,
	unique_loot = function(carry_id)
		local entry = tweak_data.carry[carry_id]
		return entry and entry.is_unique_loot
	end,
}

function M.areas()
	if M._areas then
		return M._areas
	end
	local areas = {}
	for _, script in pairs(managers.mission and managers.mission:scripts() or {}) do
		for _, element in pairs(script:elements() or {}) do
			local values = element._values
			if
				element._is_inside
				and values
				and accepts[values.instigator]
				and values.trigger_on ~= "on_exit"
				and leads_to_secure(script, element, 0, {})
			then
				areas[#areas + 1] = element
			end
		end
	end
	M._areas = areas
	return areas
end

local current_carry_id
local carry_proxy = {
	carry_id = function()
		return current_carry_id
	end,
	is_linked_to_unit = function()
		return nil
	end,
}
local instigator_proxy = {
	carry_data = function()
		return carry_proxy
	end,
}

function M.contains(position, carry_id, carry_data)
	if not position or not carry_id then
		return false
	end
	current_carry_id = carry_id
	for _, area in ipairs(M.areas()) do
		local values = area._values
		if
			values.enabled
			and accepts[values.instigator](carry_id)
			and area:_is_inside(position)
			and area:_check_instigator_rules(instigator_proxy)
		then
			return true
		end
	end
	if carry_data and not carry_data:can_secure() then
		return false
	end

	for _, unit in ipairs(managers.vehicle and managers.vehicle:get_all_vehicles() or {}) do
		local driving = alive(unit) and unit:vehicle_driving()
		if
			driving
			and driving:is_accepting_loot_enabled()
			and driving._interaction_loot
			and (not driving._tweak_data or driving:get_loot() < driving._tweak_data.max_loot_bags)
			and driving:_loot_filter_func(carry_data or carry_proxy)
		then
			local point, distance = driving:get_nearest_loot_point(position)
			if point and distance <= 100 then
				return true
			end
		end
	end
	return false
end

local function secure_path(script, element, carry_id, depth, seen, alternative)
	if not element or seen[element] or depth > MAX_LINK_DEPTH then
		return nil
	end
	local values = element._values
	if not values then
		return nil
	end
	if not values.enabled then
		return 0
	end
	local is_carry = ElementCarry and element.on_executed == ElementCarry.on_executed
	if is_carry and values.type_filter and values.type_filter ~= "none" and values.type_filter ~= carry_id then
		return 0
	end
	if is_carry and SECURE_OPERATIONS[values.operation] then
		return 1
	end
	if
		not (is_carry and values.operation == "none")
		and not (MissionScriptElement and element.on_executed == MissionScriptElement.on_executed)
	then
		if leads_to_secure(script, element, 0, {}) then
			return nil
		end
		return 0
	end
	seen[element] = true
	local count = 0
	if is_carry then
		alternative = nil
	end
	for _, link in ipairs(values.on_executed or {}) do
		if not alternative or not link.alternative or link.alternative == alternative then
			local branch = secure_path(script, script:element(link.id), carry_id, depth + 1, seen, alternative)
			if not branch then
				return nil
			end
			count = count + branch
		end
	end
	seen[element] = nil
	return count
end

local function supported(area, carry_id)
	local values = area._values
	local report = CoreElementArea and CoreElementArea.ElementAreaReportTrigger
	local is_report = report and area.sync_enter_area == report.sync_enter_area
	if
		not ElementAreaTrigger
		or area.on_executed ~= ElementAreaTrigger.on_executed
		or (not is_report and area.sync_enter_area ~= ElementAreaTrigger.sync_enter_area)
		or not values.enabled
		or (not is_report and values.trigger_on ~= "on_enter")
		or values.amount == "all"
		or (tonumber(values.amount) or 1) > 1
		or (values.substitute_object and values.substitute_object ~= "")
		or (values.spawn_unit_elements and next(values.spawn_unit_elements))
		or not accepts[values.instigator](carry_id)
	then
		return false
	end
	local count = 0
	for _, link in ipairs(values.on_executed or {}) do
		if is_report and (link.alternative == "while_inside" or link.alternative == "reached_amount") then
			return false
		end
		if not is_report or not link.alternative or link.alternative == "enter" then
			local branch = secure_path(
				area._mission_script,
				area._mission_script:element(link.id),
				carry_id,
				1,
				{},
				is_report and "enter" or nil
			)
			if not branch then
				return false
			end
			count = count + branch
		end
	end
	return count == 1
end

function M.contact(position, carry_id, carry_data)
	if not position or not carry_id or (carry_data and carry_data:is_linked_to_unit()) then
		return nil
	end
	current_carry_id = carry_id
	local instigator = carry_data and {
		carry_data = function()
			return carry_data
		end,
	} or instigator_proxy
	for _, area in ipairs(M.areas()) do
		if
			type(area._id) == "number"
			and area._id > 0
			and area._id % 1 == 0
			and supported(area, carry_id)
			and area:_is_inside(position)
			and area:_check_instigator_rules(instigator)
		then
			return { area_id = area._id, position = mvector3.copy(position) }
		end
	end
	return nil
end

function M.commit(area_id, position, unit)
	if not Network:is_server() or not position or not alive(unit) then
		return false
	end
	local carry_data = unit:carry_data()
	if not carry_data or carry_data:is_linked_to_unit() or carry_data:value() <= 0 then
		return false
	end
	for _, area in ipairs(M.areas()) do
		if
			area._id == area_id
			and supported(area, carry_data:carry_id())
			and area:_is_inside(position)
			and area:_check_instigator_rules(unit)
			and area:is_instigator_valid(unit)
		then
			for _, inside in ipairs(area._inside) do
				if inside == unit then
					return false
				end
			end
			area:sync_enter_area(unit)
			return true
		end
	end
	return false
end

function M.reset()
	M._areas = nil
end

return M
