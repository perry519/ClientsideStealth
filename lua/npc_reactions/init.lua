local get_runtime, control = ...
local M = {}

local function shoutable(unit)
	local brain, damage, base = unit:brain(), unit:character_damage(), unit:base()
	local tweak = base and base:char_tweak()
	local anim = unit:anim_data()
	if
		not brain
		or not tweak
		or brain._dead
		or brain._converted
		or brain._surrendered
		or brain._is_hostage
		or damage and damage:dead()
		or anim.hands_tied
		or anim.tied
		or anim.long_dis_interact_disabled
		or unit:unit_data().disable_shout
		or base.unintimidateable
		or anim.unintimidateable
		or tweak.is_escort
	then
		return false
	end
	return tweak
end

function M.intimidatable(unit)
	local tweak = shoutable(unit)
	if not tweak or tweak.priority_shout or tweak.surrender and tweak.surrender.impossible then
		return false
	end
	return tweak
end

local function eligible(runtime, unit)
	if not alive(unit) or unit:id() < 0 then
		return false
	end
	if not runtime:current_npc_alert(unit) then
		return false
	end
	local tweak = shoutable(unit)
	if not tweak then
		return false
	end
	if CopDamage.is_civilian(unit:base()._tweak_table) then
		return tweak.intimidateable == true and tweak
	end
	return tweak
end

function M.alerted_units(enemies, civilians)
	if Network:is_server() or not managers.groupai:state():whisper_mode() then
		return nil
	end
	local runtime = get_runtime()
	if not runtime:is_active() or not control.allows_new_work("intimidation") then
		return nil
	end
	local units, candidates = {}, nil
	local enemy_units = enemies and managers.enemy:all_enemies() or {}
	for _, list in ipairs({
		enemy_units,
		civilians and managers.enemy:all_civilians() or {},
	}) do
		for key, data in pairs(list) do
			local tweak = eligible(runtime, data.unit)
			if tweak then
				units[data.unit] = tweak
				if
					list == enemy_units and (not tweak.surrender or tweak.surrender.impossible or tweak.priority_shout)
				then
					candidates = candidates or clone(enemy_units)
					local candidate = clone(data)
					candidate.char_tweak = clone(data.char_tweak)
					candidate.char_tweak.surrender = {}
					candidate.char_tweak.priority_shout = nil
					candidates[key] = candidate
					units[data.unit] = candidate.char_tweak
				end
			end
		end
	end
	return units, candidates
end

return M
