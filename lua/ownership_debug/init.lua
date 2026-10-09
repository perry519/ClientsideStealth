local get_runtime, control, bag_preview, engine_alive = ...
local unpack_args = unpack or table.unpack
local WORLD = "cst_ownership_debug"
local CHARACTER = "cst_ownership_debug_character"
local debug_view = { enabled = false, contours = {}, WORLD = WORLD, CHARACTER = CHARACTER }
local function paint_interaction(entry)
	local color_id, opacity_id = Idstring("contour_color"), Idstring("contour_opacity")
	for _, material in ipairs(entry.interaction._materials or {}) do
		if engine_alive(material) and material:variable_exists(color_id) and material:variable_exists(opacity_id) then
			if not entry.materials[material] then
				entry.materials[material] = { material:get_variable(color_id), material:get_variable(opacity_id) }
			end
			material:set_variable(color_id, entry.vector)
			material:set_variable(opacity_id, 0.3)
		end
	end
end

local function remove(unit, entry)
	if entry.contour then
		if engine_alive(unit) then
			entry.contour:remove(entry.preset, false)
		end
		return
	end
	entry.active = false
	local interaction = entry.interaction
	if interaction.set_contour == entry.wrapper then
		interaction.set_contour = entry.own_method
	end
	if engine_alive(unit) then
		local color_id, opacity_id = Idstring("contour_color"), Idstring("contour_opacity")
		for material, saved in pairs(entry.materials) do
			if engine_alive(material) then
				material:set_variable(color_id, saved[1])
				material:set_variable(opacity_id, saved[2])
			end
		end
		if entry.native_args then
			entry.original(interaction, unpack_args(entry.native_args, 1, entry.native_args.n))
		end
	end
end

function debug_view:clear()
	for unit, entry in pairs(self.contours) do
		remove(unit, entry)
	end
	self.contours = {}
	self.next_update = nil
end

function debug_view:reset()
	self:clear()
	self.enabled = false
end

function debug_view:update(now)
	if control.is_loud() then
		self:reset()
		return
	end
	if not self.enabled or self.next_update and now < self.next_update then
		return
	end
	self.next_update = now + 0.25
	local owners = get_runtime():ownership_snapshot()
	if not self.enabled then
		return
	end

	for _, record in ipairs(bag_preview.pending) do
		if record.native and owners[record.native] and engine_alive(record.unit) then
			owners[record.unit] = owners[record.native]
		end
	end
	for unit, entry in pairs(self.contours) do
		if not owners[unit] then
			remove(unit, entry)
			self.contours[unit] = nil
		end
	end
	for unit, owner in pairs(owners) do
		local color = tweak_data.chat_colors[owner]
		local contour = unit:contour()
		local interaction = not contour and unit:interaction()
		if color and contour then
			local entry = self.contours[unit]
			if not entry then
				local base = unit:base()
				local swap = base and base.is_in_original_material and base.swap_material_config
				entry = { contour = contour, preset = swap and CHARACTER or WORLD }
				self.contours[unit] = entry
			end
			if not contour:has_id(entry.preset) then
				contour:add(entry.preset, false, nil, Vector3(color.r, color.g, color.b))
			elseif entry.color ~= color then
				contour:change_color(entry.preset, Vector3(color.r, color.g, color.b))
			end
			entry.color = color

			contour:update_materials()
		elseif color and interaction and interaction.set_contour then
			local entry = self.contours[unit]
			if not entry then
				entry = {
					interaction = interaction,
					materials = {},
					active = true,
					original = interaction.set_contour,
					own_method = rawget(interaction, "set_contour"),
				}
				entry.wrapper = function(self, ...)
					entry.native_args = { n = select("#", ...), ... }
					entry.original(self, ...)
					if entry.active then
						paint_interaction(entry)
					end
				end
				interaction.set_contour = entry.wrapper
				self.contours[unit] = entry
			end
			entry.vector = Vector3(color.r, color.g, color.b)
			paint_interaction(entry)
		end
	end
end

function debug_view:toggle()
	self.enabled = not self.enabled
	if self.enabled then
		self:update(0)
	else
		self:clear()
	end
	control.status(self.enabled and "cst_status_ownership_highlights_on" or "cst_status_ownership_highlights_off")
end

return debug_view
