-- Companion "wand structure" panel (Lisp/SLIME-style).
-- When the inventory is open, reads the active wand's cards in slot order,
-- parses them into a cast-structure tree (files/wand_structure.lua), and draws
-- an indented, color-coded tree of the wand's groupings beside the inventory.
--
-- Loaded once from init.lua; M.update() is called every frame from
-- OnWorldPostUpdate. All drawing uses our own Gui at coordinates we control, so
-- it never depends on the engine's (unexposed) spell-slot positions.

local meta = dofile_once("mods/testMod/files/structure_meta.lua") or {}
local wand_structure = dofile_once("mods/testMod/files/wand_structure.lua")

local M = {}
local gui = nil

-- type -> RGB (0..1), matching the icon-recolor palette on `main`.
local COLOR = {
	PROJECTILE        = { 0.82, 0.25, 0.25 },
	STATIC_PROJECTILE = { 0.25, 0.78, 0.30 },
	MODIFIER          = { 0.30, 0.45, 0.92 },
	DRAW_MANY         = { 0.85, 0.80, 0.25 },
	MATERIAL          = { 0.80, 0.30, 0.80 },
	UTILITY           = { 0.25, 0.80, 0.80 },
	PASSIVE           = { 0.92, 0.58, 0.18 },
	OTHER             = { 0.72, 0.72, 0.72 },
}

local function pretty(id)
	local s = tostring(id):gsub("_", " "):lower()
	s = s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end)
	return s
end

-- Localized spell name ($action_*) if available, else a prettified id.
local function display_name(id)
	local m = meta[id]
	if m and m.name and type(GameTextGet) == "function" then
		local t = GameTextGet(m.name)
		if t and t ~= "" then return t end
	end
	return pretty(id)
end

local function type_color(atype)
	return COLOR[atype] or COLOR.OTHER
end

-- ---- read the active wand and its cards ------------------------------------

local function get_active_wand()
	local players = EntityGetWithTag("player_unit")
	if not players or #players == 0 then return nil end
	local inv = EntityGetFirstComponentIncludingDisabled(players[1], "Inventory2Component")
	if not inv then return nil end
	local active = ComponentGetValue2(inv, "mActiveItem")
	if not active or active == 0 then return nil end
	if not EntityHasTag(active, "wand") then return nil end
	return active
end

local function read_deck(wand)
	local cards = {}
	local children = EntityGetAllChildren(wand) or {}
	for _, child in ipairs(children) do
		local iac = EntityGetFirstComponentIncludingDisabled(child, "ItemActionComponent")
		if iac then
			local aid = ComponentGetValue2(iac, "action_id")
			local sx, sy = 0, 0
			local ic = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
			if ic then
				local vx, vy = ComponentGetValue2(ic, "inventory_slot")
				sx, sy = vx or 0, vy or 0
			end
			if aid and aid ~= "" then
				cards[#cards + 1] = { id = aid, x = sx, y = sy }
			end
		end
	end
	table.sort(cards, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	local tokens = {}
	for _, c in ipairs(cards) do tokens[#tokens + 1] = c.id end
	return tokens
end

-- ---- flatten the tree into colored, indented display lines -----------------

local function copy_list(t)
	local r = {}
	for i = 1, #t do r[i] = t[i] end
	return r
end

-- Flatten the tree into display rows. Each row carries `bars`: one color per
-- enclosing group (the rainbow nesting spines), plus its own label + color.
local function walk(rows, node, ancestor_colors)
	local mods = ""
	if node.modifiers and #node.modifiers > 0 then
		local names = {}
		for _, m in ipairs(node.modifiers) do names[#names + 1] = display_name(m) end
		mods = "[" .. table.concat(names, ", ") .. "] "
	end

	local name = display_name(node.id)
	local label
	if node.kind == "multicast" then
		label = mods .. name .. "  x" .. tostring(node.group)
	elseif node.kind == "trigger" then
		label = mods .. name .. "  (trig " .. tostring(node.payload) .. ")"
	else
		label = mods .. name
	end

	rows[#rows + 1] = { bars = copy_list(ancestor_colors), label = label, color = type_color(node.atype) }

	if node.children and #node.children > 0 then
		local child_colors = copy_list(ancestor_colors)
		child_colors[#child_colors + 1] = type_color(node.atype) -- this group's spine color
		for _, ch in ipairs(node.children) do walk(rows, ch, child_colors) end
	end
end

-- ---- phase 2: brackets drawn under the engine's SPELLS slot row -------------
--
-- The engine never exposes where it draws the spell slots, so the slot geometry
-- below is expressed as fractions of the GUI screen and tuned empirically. The
-- card order in the SPELLS row equals our token order, so node.first/last (1-
-- based token indices) map straight onto slot indices.
local PIXEL = "mods/testMod/files/ui/pixel.png"
local SLOT = {
	cx0   = 0.3377, -- center x of slot 0, as a fraction of GUI screen width
	pitch = 0.0635, -- slot-to-slot spacing, fraction of width
	halfw = 0.0185, -- half slot width, fraction of width
	row_y = 0.126,  -- y just below the slot row, fraction of GUI screen height
}
local LEVEL_GAP = 9 -- px between nesting bracket levels
local TICK = 4      -- px height of the end ticks

local function line(gui, id, x, y, w, h, c)
	GuiColorSetForNextWidget(gui, c[1], c[2], c[3], 1)
	GuiImage(gui, id, x, y, PIXEL, 1, w, h)
end

local function draw_slot_brackets(gui, nodes, sw, sh, depth, idc)
	for _, node in ipairs(nodes) do
		if node.children and #node.children > 0 and node.first and node.last then
			local a, b = node.first - 1, node.last - 1 -- 0-based slot indices
			local lx = sw * SLOT.cx0 + a * sw * SLOT.pitch - sw * SLOT.halfw
			local rx = sw * SLOT.cx0 + b * sw * SLOT.pitch + sw * SLOT.halfw
			local yt = sh * SLOT.row_y + depth * LEVEL_GAP
			local c = type_color(node.atype)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, lx, yt, rx - lx, 1, c)         -- horizontal
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, lx, yt - TICK, 1, TICK + 1, c) -- left end tick
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx, yt - TICK, 1, TICK + 1, c) -- right end tick

			local lbl = (node.kind == "multicast") and ("x" .. tostring(node.group))
				or ("trig " .. tostring(node.payload))
			local lw = (GuiGetTextDimensions(gui, lbl))
			GuiColorSetForNextWidget(gui, c[1], c[2], c[3], 1)
			GuiText(gui, (lx + rx) / 2 - lw / 2, yt + 1, lbl)

			draw_slot_brackets(gui, node.children, sw, sh, depth + 1, idc)
		end
	end
end

-- ---- companion structure panel (phase 1) -----------------------------------

local function draw_panel(gui, tree, sw)
	local rows = {}
	for _, node in ipairs(tree) do walk(rows, node, {}) end
	if #rows == 0 then return end

	local title = "Wand structure"
	local line_h = 11
	local pad = 4
	local bar_w = (GuiGetTextDimensions(gui, "| ")) -- horizontal advance per nesting spine

	local max_w = (GuiGetTextDimensions(gui, title))
	for _, r in ipairs(rows) do
		local w = #r.bars * bar_w + (GuiGetTextDimensions(gui, r.label))
		if w > max_w then max_w = w end
	end

	local panel_w = max_w + pad * 2
	local panel_h = (#rows + 1) * line_h + pad * 2
	local px = math.floor((sw - panel_w) / 2) -- center-top, clear of side boxes and right HUD
	local y0 = 60

	GuiZSet(gui, 4)
	GuiImageNinePiece(gui, 90210, px - pad, y0 - pad, panel_w, panel_h, 0.85)

	GuiZSet(gui, 1)
	GuiText(gui, px, y0, title)
	local y = y0 + line_h + 2
	for _, r in ipairs(rows) do
		local x = px
		for _, bc in ipairs(r.bars) do -- rainbow nesting spines
			GuiColorSetForNextWidget(gui, bc[1], bc[2], bc[3], 1)
			GuiText(gui, x, y, "|")
			x = x + bar_w
		end
		GuiColorSetForNextWidget(gui, r.color[1], r.color[2], r.color[3], 1)
		GuiText(gui, x, y, r.label)
		y = y + line_h
	end
end

-- ---- per-frame entry point -------------------------------------------------

function M.update()
	if type(GameIsInventoryOpen) ~= "function" or not GameIsInventoryOpen() then return end
	if not wand_structure then return end

	local get = (type(ModSettingGet) == "function") and ModSettingGet or function() return nil end
	local show_panel = get("testMod.show_grouping") ~= false
	local show_slots = get("testMod.show_slot_brackets") ~= false
	if not show_panel and not show_slots then return end

	local wand = get_active_wand()
	if not wand then return end

	local tokens = read_deck(wand)
	if #tokens == 0 then return end

	local tree = wand_structure.build(tokens, meta)

	if gui == nil then gui = GuiCreate() end
	GuiStartFrame(gui)
	local sw, sh = GuiGetScreenDimensions(gui)

	if show_slots then
		GuiZSet(gui, 1)
		draw_slot_brackets(gui, tree, sw, sh, 0, { n = 0 })
	end
	if show_panel then
		draw_panel(gui, tree, sw)
	end
end

return M
