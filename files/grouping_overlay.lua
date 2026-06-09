-- Companion "wand structure" panel (Lisp/SLIME-style).
-- When the inventory is open, reads the active wand's cards in slot order plus
-- its gun_config (spells/cast, shuffle), simulates the cast sequence
-- (files/wand_structure.lua), and draws an indented, color-coded tree of each
-- cast's groupings -- including when the wand WRAPS (forced draws past the
-- deck's end pulling cards from the wand's start: the rapid-fire mechanic).
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
local HEADER_COLOR = { 0.85, 0.85, 0.85 }
local WRAP_COLOR   = { 1.00, 0.45, 0.15 } -- loud: wrapping is the headline info

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

-- ---- read the active wand, its cards and its gun_config ---------------------

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

-- spells/cast + shuffle from the wand's AbilityComponent.gun_config.
-- Verified in-game 2026-06-09. Still pcall-guarded: an error here would
-- disable the whole panel (init.lua kills it on first error), so a future
-- game update changing these fields degrades to 1/cast, no shuffle.
local function read_config(wand)
	local cfg = { spells_per_cast = 1, shuffle = false }
	if type(ComponentObjectGetValue2) ~= "function" then return cfg end
	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if not ab then return cfg end
	local ok, spc = pcall(ComponentObjectGetValue2, ab, "gun_config", "actions_per_round")
	if ok and tonumber(spc) and tonumber(spc) > 0 then cfg.spells_per_cast = tonumber(spc) end
	local ok2, sh = pcall(ComponentObjectGetValue2, ab, "gun_config", "shuffle_deck_when_empty")
	cfg.shuffle = ok2 and sh == true
	return cfg
end

-- Returns the deck tokens (slot order) and the always-cast ids separately:
-- always-cast cards never sit in the deck -- the engine plays them at the
-- start of every cast -- so they must not take part in the deck simulation.
local function read_deck(wand)
	local cards, always = {}, {}
	local children = EntityGetAllChildren(wand) or {}
	for _, child in ipairs(children) do
		local iac = EntityGetFirstComponentIncludingDisabled(child, "ItemActionComponent")
		if iac then
			local aid = ComponentGetValue2(iac, "action_id")
			local sx, sy, perm = 0, 0, false
			local ic = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
			if ic then
				local vx, vy = ComponentGetValue2(ic, "inventory_slot")
				sx, sy = vx or 0, vy or 0
				-- pcall: not yet verified in-game; degrade to "not always-cast"
				local ok, p = pcall(ComponentGetValue2, ic, "permanently_attached")
				perm = ok and p == true
			end
			if aid and aid ~= "" then
				if perm then
					always[#always + 1] = aid
				else
					cards[#cards + 1] = { id = aid, x = sx, y = sy }
				end
			end
		end
	end
	table.sort(cards, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	-- tokens = deck order; xs[i] = that card's real slot column, so brackets
	-- land right even when the wand has leading/interior empty slots.
	local tokens, xs = {}, {}
	for _, c in ipairs(cards) do
		tokens[#tokens + 1] = c.id
		xs[#xs + 1] = c.x
	end
	return tokens, always, xs
end

-- ---- flatten the simulation into colored, indented display lines -------------

local function copy_list(t)
	local r = {}
	for i = 1, #t do r[i] = t[i] end
	return r
end

-- Flatten one node into display rows. Each row carries `bars`: one color per
-- enclosing group (the rainbow nesting spines), plus its own label + color.
-- Nodes parsed across a wand wrap get a "~" prefix (the card came around).
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
		local count = (node.group == -1) and "all" or tostring(node.group)
		label = mods .. name .. "  x" .. count
	elseif node.kind == "trigger" then
		label = mods .. name .. "  (trig " .. tostring(node.payload) .. ")"
	else
		label = mods .. name
	end
	if node.dangling then label = label .. "  (no projectile)" end
	if node.wrap then label = "~ " .. label end

	rows[#rows + 1] = { bars = copy_list(ancestor_colors), label = label, color = type_color(node.atype) }

	if node.children and #node.children > 0 then
		local child_colors = copy_list(ancestor_colors)
		child_colors[#child_colors + 1] = type_color(node.atype) -- this group's spine color
		for _, ch in ipairs(node.children) do walk(rows, ch, child_colors) end
	end
end

-- Rows for the whole simulation: per-cast headers (when there is more than one
-- cast or a wrap), the trees, and a loud wrap/recharge banner.
local function sim_rows(sim, cfg, always)
	local rows = {}
	if #always > 0 then
		local names = {}
		for _, id in ipairs(always) do names[#names + 1] = display_name(id) end
		rows[#rows + 1] = { bars = {}, label = "always: " .. table.concat(names, ", "),
			color = COLOR.PASSIVE }
	end
	local show_headers = (#sim.casts > 1) or sim.wrapped
	for ci, cast in ipairs(sim.casts) do
		if show_headers then
			local h = "cast " .. ci
			if cast.wrapped then h = h .. "  -- WRAPS! -> recharge" end
			rows[#rows + 1] = { bars = {}, label = h,
				color = cast.wrapped and WRAP_COLOR or HEADER_COLOR, header = true }
		end
		local spine = show_headers and { HEADER_COLOR } or {}
		for _, node in ipairs(cast.nodes) do walk(rows, node, spine) end
	end
	return rows
end

-- ---- phase 2: paren-style delimiters on each WAND BOX's spell row -----------
--
-- EXPERIMENTAL (off by default). The engine doesn't expose where it draws the
-- wand boxes, so the layout below is a hand-calibrated stacking model in
-- GUI-screen fractions (re-measured 2026-06-09 from a 2000x1125 screenshot,
-- GUI 640x360). Instead of long underlines spanning the whole group (ugly
-- across empty slots), each group gets Lisp-style [ ] delimiters hugging its
-- first and last card, in the group's color, label above the opening one.
-- The selected box renders taller and shifts everything below it; the selected
-- box IS the held wand (Inventory2Component.mActiveItem), so we correct for it.
local PIXEL = "mods/testMod/files/ui/pixel.png"
local BOX = {
	bottom0   = 0.295,  -- box 1 slot-row BOTTOM, fraction of GUI height
	step      = 0.170,  -- per-box vertical step (non-selected), fraction of height
	sel_extra = 0.051,  -- extra shift for the selected box and every box below it
	slot_h    = 0.058,  -- slot height, fraction of GUI height (~21 GUI)
	slot0_x   = 0.056,  -- first slot CENTER, fraction of GUI width (~36 GUI)
	pitch     = 0.0325, -- slot-to-slot spacing, fraction of width (~21 GUI)
	halfw     = 0.016,  -- half slot width, fraction of width (~10 GUI)
}
local NEST_GAP = 3        -- px between delimiters stacked at the same column
local DEBUG_RULER = false -- set true to draw GUI dims + a 10% grid for calibration

local function line(gui, id, x, y, w, h, c, a)
	a = a or 1
	GuiColorSetForNextWidget(gui, c[1], c[2], c[3], a)
	GuiImage(gui, id, x, y, PIXEL, a, w, h)
end

-- Draw [ ] delimiters for one group: a vertical bar with two small ticks
-- pointing into the group, slot height, snug against the boundary cards.
-- `opens`/`closes` count delimiters already placed per column so nested
-- delimiters at the same card nudge outward instead of overlapping. The
-- close is placed AFTER recursing so a parent's ] lands outside its kids'.
-- `xs` maps deck index -> real slot column (handles empty slots in the wand).
local function draw_delims(gui, nodes, sw, top, bot, idc, xs, opens, closes)
	for _, node in ipairs(nodes) do
		if node.children and #node.children > 0 and node.first and node.last then
			local ca = xs[node.first] or (node.first - 1) -- 0-based slot columns
			local cb = xs[node.last] or (node.last - 1)
			local c = node.wrap and WRAP_COLOR or type_color(node.atype)
			local h = bot - top

			local off_a = opens[ca] or 0
			opens[ca] = off_a + 1
			local lx = sw * (BOX.slot0_x + ca * BOX.pitch - BOX.halfw) - 2 - off_a * NEST_GAP
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, lx, top, 1, h, c)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, lx, top, 3, 1, c)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, lx, bot - 1, 3, 1, c)

			local lbl
			if node.kind == "multicast" then
				lbl = "x" .. ((node.group == -1) and "all" or tostring(node.group))
			else
				lbl = "trig " .. tostring(node.payload)
			end
			if node.wrap then lbl = lbl .. " ~wrap" end
			GuiColorSetForNextWidget(gui, c[1], c[2], c[3], 1)
			GuiText(gui, lx, top - 9, lbl)

			draw_delims(gui, node.children, sw, top, bot, idc, xs, opens, closes)

			local off_b = closes[cb] or 0
			closes[cb] = off_b + 1
			local rx = sw * (BOX.slot0_x + cb * BOX.pitch + BOX.halfw) + 2 + off_b * NEST_GAP
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx, top, 1, h, c)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx - 2, top, 3, 1, c)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx - 2, bot - 1, 3, 1, c)
		end
	end
end

-- Enumerate carried wands (in quick-slot order) and delimit each one's box row.
local function draw_box_brackets(gui, sw, sh)
	local players = EntityGetWithTag("player_unit")
	if not players or #players == 0 then return end
	local items = GameGetAllInventoryItems(players[1]) or {}

	local wands = {}
	for _, it in ipairs(items) do
		if EntityHasTag(it, "wand") then
			local sx = 0
			local ic = EntityGetFirstComponentIncludingDisabled(it, "ItemComponent")
			if ic then sx = ComponentGetValue2(ic, "inventory_slot") or 0 end
			wands[#wands + 1] = { e = it, slot = sx }
		end
	end
	table.sort(wands, function(p, q) return p.slot < q.slot end)

	-- the selected (taller) box is the held wand's box
	local sel_idx = nil
	local inv = EntityGetFirstComponentIncludingDisabled(players[1], "Inventory2Component")
	local active = inv and ComponentGetValue2(inv, "mActiveItem")
	if active and active ~= 0 then
		for idx, wd in ipairs(wands) do
			if wd.e == active then sel_idx = idx end
		end
	end

	local idc = { n = 0 }
	for idx, wd in ipairs(wands) do
		local bottom = BOX.bottom0 + (idx - 1) * BOX.step
		if sel_idx and idx >= sel_idx then bottom = bottom + BOX.sel_extra end
		local bot = sh * bottom
		local top = bot - sh * BOX.slot_h
		local tokens, _, xs = read_deck(wd.e)
		if #tokens > 0 then
			local cfg = read_config(wd.e)
			local sim = wand_structure.simulate(tokens, meta,
				{ spells_per_cast = cfg.spells_per_cast })
			for _, cast in ipairs(sim.casts) do
				draw_delims(gui, cast.nodes, sw, top, bot, idc, xs, {}, {})
			end
		end
	end
end

-- Temporary calibration aid: prints GUI dimensions and a 10% grid so the
-- screenshot-pixel <-> GUI-coordinate mapping can be measured exactly.
local function draw_debug(gui, sw, sh)
	GuiColorSetForNextWidget(gui, 1, 1, 0, 1)
	GuiText(gui, 4, 2, "GUI " .. math.floor(sw + 0.5) .. "x" .. math.floor(sh + 0.5))
	for f = 1, 9 do
		line(gui, 80000 + f, sw * f / 10, 0, 1, sh, { 0.3, 0.6, 1 }, 0.35)
		GuiColorSetForNextWidget(gui, 0.3, 0.6, 1, 1); GuiText(gui, sw * f / 10 + 1, 12, tostring(f * 10))
		line(gui, 80100 + f, 0, sh * f / 10, sw, 1, { 0.3, 1, 0.4 }, 0.35)
		GuiColorSetForNextWidget(gui, 0.3, 1, 0.4, 1); GuiText(gui, 2, sh * f / 10, tostring(f * 10))
	end
end

-- ---- companion structure panel (phase 1) -----------------------------------

local function draw_panel(gui, rows, title, sw)
	if #rows == 0 then return end

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
		local bars = r.bars
		if r.header then bars = {} end -- headers sit flush left
		for _, bc in ipairs(bars) do   -- rainbow nesting spines
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
	local show_slots = get("testMod.show_slot_brackets") == true
	if not show_panel and not show_slots then return end

	if gui == nil then gui = GuiCreate() end
	GuiStartFrame(gui)
	local sw, sh = GuiGetScreenDimensions(gui)

	if show_slots then -- brackets on every wand box (independent of active wand)
		GuiZSet(gui, 1)
		draw_box_brackets(gui, sw, sh)
		if DEBUG_RULER then draw_debug(gui, sw, sh) end
	end

	if show_panel then -- companion cast-structure tree for the active/held wand
		local wand = get_active_wand()
		if wand then
			local tokens, always = read_deck(wand)
			if #tokens > 0 or #always > 0 then
				local cfg = read_config(wand)
				local sim = wand_structure.simulate(tokens, meta,
					{ spells_per_cast = cfg.spells_per_cast })
				-- Shuffle wands randomize draw order at cast time, so the
				-- slot-order simulation is only one possible outcome.
				local title = "Wand structure  (" .. cfg.spells_per_cast .. "/cast)"
				if cfg.shuffle then
					title = "Wand structure  (" .. cfg.spells_per_cast
						.. "/cast, shuffle: order varies!)"
				end
				draw_panel(gui, sim_rows(sim, cfg, always), title, sw)
			end
		end
	end
end

return M
