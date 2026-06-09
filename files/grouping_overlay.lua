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

local function emit(lines, node, depth)
	local indent = string.rep("  ", depth)
	local mods = ""
	if node.modifiers and #node.modifiers > 0 then
		local names = {}
		for _, m in ipairs(node.modifiers) do names[#names + 1] = pretty(m) end
		mods = "[" .. table.concat(names, ", ") .. "] "
	end

	local label
	if node.kind == "multicast" then
		label = indent .. mods .. "x" .. tostring(node.group) .. " " .. pretty(node.id)
	elseif node.kind == "trigger" then
		label = indent .. mods .. pretty(node.id) .. " <trig " .. tostring(node.payload) .. ">"
	else
		label = indent .. mods .. pretty(node.id)
	end

	local c = COLOR[node.atype] or COLOR.OTHER
	lines[#lines + 1] = { text = label, r = c[1], g = c[2], b = c[3] }

	if node.children then
		for _, ch in ipairs(node.children) do emit(lines, ch, depth + 1) end
	end
end

-- ---- per-frame entry point -------------------------------------------------

function M.update()
	if type(GameIsInventoryOpen) ~= "function" or not GameIsInventoryOpen() then return end
	if type(ModSettingGet) == "function" and ModSettingGet("testMod.show_grouping") == false then return end
	if not wand_structure then return end

	local wand = get_active_wand()
	if not wand then return end

	local tokens = read_deck(wand)
	if #tokens == 0 then return end

	local tree = wand_structure.build(tokens, meta)
	local lines = {}
	for _, node in ipairs(tree) do emit(lines, node, 0) end
	if #lines == 0 then return end

	if gui == nil then gui = GuiCreate() end
	GuiStartFrame(gui)

	local sw, _sh = GuiGetScreenDimensions(gui)
	local x = sw - 132
	local y0 = 30
	local line_h = 10
	local panel_h = (#lines + 1) * line_h + 8

	GuiZSet(gui, 2)
	GuiImageNinePiece(gui, 90210, x - 4, y0 - 4, 130, panel_h, 0.55)

	GuiZSet(gui, 1)
	GuiText(gui, x, y0, "Wand structure")
	local y = y0 + line_h + 2
	for _, ln in ipairs(lines) do
		GuiColorSetForNextWidget(gui, ln.r, ln.g, ln.b, 1)
		GuiText(gui, x, y, ln.text)
		y = y + line_h
	end
end

return M
