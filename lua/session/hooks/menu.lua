local options, features, settings = ...
local M = {}
local PREFIX = "cst_feature_"
local CALLBACK = "ClientsideStealthFeatureToggle"
local FOCUS = "ClientsideStealthOptionsFocus"
local REFRESH = "ClientsideStealthOptionsRefresh"
local LOBBY_SLOT = "cst_lobby_peer_"
local INDENT = 16
local TEXT_GAP = 8

local function count_suffix(count)
	return count > 1 and " (" .. count .. ")" or ""
end

local function item_id(index, entry)
	return entry.setting and PREFIX .. entry.setting
		or entry.page and "cst_page_" .. entry.page
		or "cst_divider_" .. index
end

local function reload_indented_heading(item, row_item, node)
	MenuItemDivider.reload(item, row_item, node)
	if row_item.text then
		row_item.text:set_x(INDENT)
	end
	return true
end

local function shade(color, factor)
	return Color(color.a, color.r * factor, color.g * factor, color.b * factor)
end

local function whiten(color, amount)
	return Color(
		color.a,
		color.r + (1 - color.r) * amount,
		color.g + (1 - color.g) * amount,
		color.b + (1 - color.b) * amount
	)
end

local function status_colors(status)
	local colors = tweak_data.screen_colors
	if status == "pending" then
		return whiten(colors.button_stage_3, 0.55), whiten(colors.button_stage_2, 0.55)
	elseif status == "unavailable" then
		return shade(colors.button_stage_3, 0.5), shade(colors.button_stage_2, 0.6)
	elseif status == "paused" then
		return Color(1, 0.8, 0.55, 0.2), Color(1, 1, 0.72, 0.3)
	end
end

local function style(item, text, help, status)
	local params = item._parameters
	params.text_id, params.help_id, params.localize, params.localize_help = text, help, false, false
	params.row_item_color, params.hightlight_color = status_colors(status)
end

local function feature_list(names)
	local listed, titles = {}, {}
	for _, name in ipairs(names) do
		listed[name] = true
	end
	for _, entry in ipairs(options.items) do
		if entry.setting and listed[entry.setting] then
			titles[#titles + 1] = managers.localization:text(entry.title)
		end
	end
	return table.concat(titles, ", ")
end

local function describe(row, name)
	local loc = managers.localization
	if not row.mode and not row.using then
		return string.format(loc:text("cst_lobby_missing"), name), loc:text("cst_lobby_missing_desc"), "unavailable"
	end
	local mode = loc:text(row.mode and "cst_lobby_" .. row.mode or "cst_lobby_connecting")
	if not row.using then
		return string.format(loc:text("cst_lobby_connected"), name, mode), loc:text("cst_lobby_waiting")
	end
	local text = row.using == 0 and string.format(loc:text("cst_lobby_off"), name, mode)
		or row.using == row.allowed and string.format(
			loc:text(row.host and "cst_lobby_all" or "cst_lobby_all_allowed"),
			name,
			mode
		)
		or string.format(loc:text("cst_lobby_features"), name, mode, row.using, row.allowed)
	local help = {}
	if row.off[1] then
		help[#help + 1] = string.format(loc:text("cst_lobby_not_using"), feature_list(row.off))
	end
	if row.blocked[1] then
		help[#help + 1] = string.format(loc:text("cst_lobby_blocked"), feature_list(row.blocked))
	end
	return text,
		help[1] and table.concat(help, "\n") or loc:text(row.host and "cst_lobby_host_uses_all" or "cst_lobby_uses_all"),
		row.using == 0 and "unavailable" or nil
end

local function refresh_lobby(node)
	local loc = managers.localization
	local rows = features.lobby() or {}
	local session = managers.network and managers.network:session()
	for slot = 1, math.huge do
		local item = node:item(LOBBY_SLOT .. slot)
		if not item then
			break
		end
		if rows[slot] then
			local row = rows[slot]
			local peer = session and session:peer(row.id)
			local name = peer and Hooks:ReturnCall("ClientsideStealthDisplayName", peer)
			style(item, describe(row, type(name) == "string" and name ~= "" and name or row.name))
		else
			style(item, loc:text("cst_lobby_empty"), loc:text("cst_lobby_desc"))
		end
		item:set_visible(rows[slot] ~= nil or slot == 1)
	end
end

local function on_focus(...)
	return MenuCallbackHandler[FOCUS](...)
end

local function reload_toggle(item, row_item, node)
	local result = item.reload_toggle(item, row_item, node)
	if row_item and row_item.gui_icon then
		row_item.gui_text:set_left(row_item.gui_icon:right() + TEXT_GAP)
	end
	return result
end

local function layout_items(node)
	for index, entry in ipairs(options.items) do
		local item = node:item(item_id(index, entry))
		if item and entry.setting then
			item._parameters.align = "left"
			item._parameters.expand_value = entry.indent and INDENT * (tonumber(entry.indent) or 1) or nil
			item.reload_toggle, item.reload = item.reload_toggle or item.reload, reload_toggle
		elseif item and entry.indent then
			item.reload = reload_indented_heading
		end
	end
end

function M:install()
	if self._installed then
		return
	end
	self._installed = true

	local function refresh_node(node)
		for index, entry in ipairs(options.items) do
			local item = node:item(item_id(index, entry))
			if item then
				if entry.setting then
					local loc = managers.localization
					local status, reason = features.status(entry.setting)
					item:set_value(settings.get(entry.setting) and "on" or "off")
					style(
						item,
						loc:text(entry.title),
						loc:text(entry.desc) .. (reason and "\n" .. loc:text(reason) or ""),
						status
					)
				end
				if entry.connection then
					local key, rpc, lua = features.connection()
					item._parameters.text_id = key
							and managers.localization:text(
								key,
								{ RPC_COUNT = count_suffix(rpc), LUA_COUNT = count_suffix(lua) }
							)
						or ""
					item._parameters.localize = false
					item:set_visible(key ~= nil)
				elseif entry.page then
					item:set_visible(features.lobby() ~= nil)
				else
					item:set_visible(
						(entry.always or settings.get("enabled")) and (not entry.parent or settings.get(entry.parent))
					)
				end
			end
		end
	end

	local function style_node(node)
		if node:item(item_id(1, options.items[1])) then
			refresh_node(node)
		elseif node:item(LOBBY_SLOT .. 1) then
			refresh_lobby(node)
		else
			return false
		end
		return true
	end

	local function refresh()
		local menu = managers.menu and managers.menu:active_menu()
		local logic = menu and menu.logic
		local node = logic and logic:selected_node()
		if node and style_node(node) then
			logic:refresh_node()
		end
	end

	MenuCallbackHandler[CALLBACK] = function(_, item)
		features.set(item:name():sub(#PREFIX + 1), item:value() == "on")
		refresh()
	end

	MenuCallbackHandler[FOCUS] = function(node, focus)
		if focus and style_node(node) then
			local menu = managers.menu:active_menu()
			if menu and menu.logic:selected_node() == node then
				menu.logic:refresh_node()
			end
		end
	end

	if not MenuCallbackHandler[REFRESH] then
		features.on_status_changed(function()
			MenuCallbackHandler[REFRESH]()
		end)
	end
	MenuCallbackHandler[REFRESH] = refresh

	Hooks:Add("MenuManagerSetupCustomMenus", "ClientsideStealthSetupMenu", function()
		MenuHelper:NewMenu(options.menu_id)
		MenuHelper:NewMenu(options.lobby.menu_id)
	end)
	Hooks:Add("MenuManagerPopulateCustomMenus", "ClientsideStealthPopulateMenu", function()
		for index, entry in ipairs(options.items) do
			local priority = #options.items - index + 1
			if entry.setting then
				MenuHelper:AddToggle({
					id = item_id(index, entry),
					title = entry.title,
					desc = entry.desc,
					callback = CALLBACK,
					value = settings.get(entry.setting),
					icon_by_text = true,
					menu_id = options.menu_id,
					priority = priority,
					localized = true,
				})
			elseif entry.page then
				local page = options[entry.page]
				MenuHelper:AddButton({
					id = item_id(index, entry),
					title = page.title,
					desc = page.desc,
					next_node = page.menu_id,
					menu_id = options.menu_id,
					priority = priority,
					localized = true,
				})
			else
				MenuHelper:AddDivider({
					id = item_id(index, entry),
					title = entry.heading,
					no_text = entry.heading == nil,
					size = entry.heading and 24 or 16,
					menu_id = options.menu_id,
					priority = priority,
					localized = true,
				})
			end
		end
		local slots = math.max((tweak_data.max_players or 4) - 1, 1)
		for slot = 1, slots do
			MenuHelper:AddButton({
				id = LOBBY_SLOT .. slot,
				title = "cst_lobby_empty",
				desc = "cst_lobby_desc",
				menu_id = options.lobby.menu_id,
				priority = slots - slot + 1,
				localized = true,
			})
		end
	end)
	Hooks:Add("MenuManagerBuildCustomMenus", "ClientsideStealthBuildMenu", function(_, menu_nodes)
		local node = MenuHelper:BuildMenu(options.menu_id)
		local lobby = MenuHelper:BuildMenu(options.lobby.menu_id)
		node:parameters().focus_changed_callback, lobby:parameters().focus_changed_callback = { on_focus }, { on_focus }
		menu_nodes[options.menu_id], menu_nodes[options.lobby.menu_id] = node, lobby
		layout_items(node)
		MenuHelper:AddMenuItem(menu_nodes.blt_options, options.menu_id, options.title, options.desc)
	end)
end

return M
