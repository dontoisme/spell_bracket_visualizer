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

-- type -> RGB (0..1) for panel row labels (the retired icon-recolor palette).
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

-- SLIME-style rainbow: nesting color cycles by depth (panel spines and slot
-- delimiters share it; wrap groups override with WRAP_COLOR -- the wrap
-- signal outranks pretty).
local RAINBOW = {
	{ 1.00, 0.85, 0.30 }, -- gold
	{ 0.45, 0.85, 1.00 }, -- sky
	{ 0.55, 1.00, 0.55 }, -- green
	{ 1.00, 0.55, 0.85 }, -- pink
	{ 0.80, 0.65, 1.00 }, -- violet
	{ 1.00, 0.70, 0.40 }, -- amber
}

local function nest_color(depth)
	return RAINBOW[(depth % #RAINBOW) + 1]
end

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
-- enclosing group -- SLIME rainbow by nesting depth (wrap groups in
-- WRAP_COLOR) -- plus its own label + type color.
-- Nodes parsed across a wand wrap get a "~" prefix (the card came around).
local function walk(rows, node, ancestor_colors, depth)
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
		child_colors[#child_colors + 1] = node.wrap and WRAP_COLOR or nest_color(depth)
		for _, ch in ipairs(node.children) do walk(rows, ch, child_colors, depth + 1) end
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
		for _, node in ipairs(cast.nodes) do walk(rows, node, spine, 0) end
	end
	return rows
end

-- ---- phase 2: paren-style delimiters on each WAND BOX's spell row -----------
--
-- The engine doesn't expose where it draws the
-- wand boxes, so the layout below is a hand-calibrated stacking model in
-- GUI-screen fractions (re-measured 2026-06-09 from a 2000x1125 screenshot,
-- GUI 640x360). Instead of long underlines spanning the whole group (ugly
-- across empty slots), each group gets Lisp-style [ ] delimiters hugging its
-- first and last card, in the group's color, label above the opening one.
-- The selected box renders taller and shifts everything below it; the selected
-- box IS the held wand (Inventory2Component.mActiveItem), so we correct for it.
local PIXEL = "mods/testMod/files/ui/pixel.png"
-- The wand boxes are laid out in engine-UI units (5 screen px each at
-- 2000x1125 = 0.0025 of GUI width; slots are 13u pitch / 12u frames). Box
-- HEIGHT is per-wand with a FLOOR: max(37u, 14u + 2u per wand-sprite pixel).
-- Small wands (art <= 11 px) all get the 37u minimum -- which both explains
-- why most boxes look uniform and absorbs sprite-read error for them; only
-- tall art (13/15/17 px) grows the box. Selection contributes NOTHING (the
-- old "selected box is taller" theory was a tall wand sprite in disguise).
-- Calibrated against the circled 4-wand screenshot, all rows within 1u.
-- If rows drift again: flip the "Calibration Overlay" mod setting, take one
-- screenshot -- it shows computed rows + raw sprite reads to recalibrate.
local U = 0.0025 -- one engine-UI unit, as a fraction of GUI width
local BOX = {
	top0    = 30,     -- units: top of wand box 1
	min_h   = 37,     -- units: minimum box height (floor)
	h_pad   = 14,     -- units: box height = max(min_h, h_pad + s_scale * sprite_h)
	s_scale = 2,      -- units of box height per wand-sprite pixel
	gap     = 2,      -- units between consecutive boxes
	row_off = 2,      -- units: slot-row bottom sits this far above the box bottom
	slot_h  = 12,     -- units: card frame height
	slot0_x = 0.056,  -- first slot CENTER, fraction of GUI width (22.4u)
	pitch   = 0.0325, -- slot-to-slot spacing, fraction of width (13u)
	halfw   = 0.015,  -- half width of the card FRAME, fraction of width (6u)
}
local BAR_W   = 1   -- GUI width of a bracket's vertical bar
local TICK_W  = 3   -- GUI length of the top/bottom hooks
local STACK_X = 1.5 -- horizontal step between closing brackets stacked on one card
local STACK_Y = 1   -- vertical growth per stack level: outer brackets are taller,
                    -- so their hooks wrap around the inner bracket's
local CLOSE_NUDGE = 1.5 -- the card frame's right edge sits ~1.5 GUI left of the
                        -- pitch-derived edge (measured from screenshot)
local OPEN_NUDGE  = 1   -- open [ sits just OFF the card, over the slot's left edge
local DEBUG_RULER = false -- set true to draw GUI dims + a 10% grid for calibration

local function line(gui, id, x, y, w, h, c, a)
	a = a or 1
	GuiColorSetForNextWidget(gui, c[1], c[2], c[3], a)
	GuiImage(gui, id, x, y, PIXEL, a, w, h)
end

-- One [ or ] glyph: vertical bar from top..bot plus two hooks pointing into
-- the group (dir = 1 for an opening [, -1 for a closing ]).
local function bracket(gui, idc, x, top, bot, dir, c)
	idc.n = idc.n + 1; line(gui, 70000 + idc.n, x, top, BAR_W, bot - top, c)
	local tx = (dir > 0) and x or (x - TICK_W + BAR_W)
	idc.n = idc.n + 1; line(gui, 70000 + idc.n, tx, top, TICK_W, 1, c)
	idc.n = idc.n + 1; line(gui, 70000 + idc.n, tx, bot - 1, TICK_W, 1, c)
end

-- Collect one wand's group delimiters (all casts) for two-pass rendering.
-- Two passes because closing brackets need the per-column TOTAL before any
-- can be placed: the OUTERMOST sits on the card's right edge and inner ones
-- step left over the card art (inner -> outer reads left -> right, like
-- nested parens on paper). Parents are collected before their children, so
-- per column the collection order is outer -> inner.
-- The span starts at the group's OWN card (node.head): leading modifiers sit
-- outside the parens, Lisp-style, matching the panel's "[mods] name" layout.
-- `xs` maps deck index -> real slot column (handles empty slots in the wand).
local function collect_delims(nodes, depth, xs, out)
	for _, node in ipairs(nodes) do
		if node.children and #node.children > 0 and node.last then
			local head = node.head or node.first
			local lbl
			if node.kind == "multicast" then
				lbl = "x" .. ((node.group == -1) and "all" or tostring(node.group))
			else
				lbl = "trig " .. tostring(node.payload)
			end
			if node.wrap then lbl = lbl .. " ~wrap" end
			out[#out + 1] = {
				ca = xs[head] or (head - 1), -- 0-based slot columns
				cb = xs[node.last] or (node.last - 1),
				c = node.wrap and WRAP_COLOR or nest_color(depth),
				lbl = lbl,
				-- wrapped-in segment (cards pulled from the wand's start)
				w1 = node.wfirst and (xs[node.wfirst] or (node.wfirst - 1)) or nil,
				w2 = node.wlast and (xs[node.wlast] or (node.wlast - 1)) or nil,
			}
			collect_delims(node.children, depth + 1, xs, out)
		end
	end
end

local function draw_delims(gui, groups, sw, top, bot, idc)
	local counts, seen = {}, {}
	for _, g in ipairs(groups) do counts[g.cb] = (counts[g.cb] or 0) + 1 end
	for _, g in ipairs(groups) do
		-- open: [ just left of the card, over the slot's left edge, label above
		local lx = sw * (BOX.slot0_x + g.ca * BOX.pitch - BOX.halfw) - OPEN_NUDGE
		bracket(gui, idc, lx, top, bot, 1, g.c)
		GuiColorSetForNextWidget(gui, g.c[1], g.c[2], g.c[3], 1)
		GuiText(gui, lx, top - 9, g.lbl)

		-- close: outermost ] ON the card's right edge (s = 0: collected
		-- first, placed rightmost, tallest so its hooks wrap the inner
		-- ones); inner brackets step LEFT over the card art, so the stack
		-- reads inner -> outer left-to-right and stays within the card
		local s = seen[g.cb] or 0
		seen[g.cb] = s + 1
		local grow = (counts[g.cb] - 1 - s) * STACK_Y
		local rx = sw * (BOX.slot0_x + g.cb * BOX.pitch + BOX.halfw)
			- BAR_W - CLOSE_NUDGE - s * STACK_X
		bracket(gui, idc, rx, top - grow, bot + grow, -1, g.c)

		-- wrap: the group continues at the wand's START. Bracket the
		-- wrapped-in segment and draw a carriage-return line under the row,
		-- from below the forward close back to the wrapped segment's [.
		if g.w1 then
			local wlx = sw * (BOX.slot0_x + g.w1 * BOX.pitch - BOX.halfw) - OPEN_NUDGE
			local wrx = sw * (BOX.slot0_x + g.w2 * BOX.pitch + BOX.halfw)
				- BAR_W - CLOSE_NUDGE
			bracket(gui, idc, wlx, top, bot, 1, g.c)
			bracket(gui, idc, wrx, top, bot, -1, g.c)
			local ry = bot + grow + 2 -- return line sits just below the row
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx, bot + grow, 1, ry - (bot + grow) + 1, g.c)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, wlx, ry, rx - wlx, 1, g.c)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, wlx, bot, 1, ry - bot + 1, g.c)
		end
	end
end

-- Read the height of this wand's art in px (pcall-guarded; vanilla wand art
-- is 3..17 px tall; cap guards against odd mod art). Also returns the file
-- for the calibration overlay. A failed read returns 9: small wands hit the
-- min_h floor anyway, so only tall-art wands need an accurate read.
local function wand_sprite_h(gui, wand)
	local sc = EntityGetFirstComponentIncludingDisabled(wand, "SpriteComponent")
	if sc then
		local ok, f = pcall(ComponentGetValue2, sc, "image_file")
		if ok and type(f) == "string" and f ~= "" then
			local ok2, _, h = pcall(GuiGetImageDimensions, gui, f, 1)
			if ok2 and tonumber(h) and h > 0 and h < 30 then return h, f end
			return 9, f
		end
	end
	return 9, "?"
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

	local debug_boxes = type(ModSettingGet) == "function"
		and ModSettingGet("testMod.debug_boxes") == true

	local idc = { n = 0 }
	local box_top = BOX.top0 -- units; boxes stack, each as tall as its wand needs
	for i, wd in ipairs(wands) do
		local s, sfile = wand_sprite_h(gui, wd.e)
		local box_h = math.max(BOX.min_h, BOX.h_pad + BOX.s_scale * s)
		local bot = (box_top + box_h - BOX.row_off) * U * sw
		local top = bot - BOX.slot_h * U * sw

		if debug_boxes then
			-- computed slot-row top (green) / bottom (red) + the raw inputs,
			-- so one screenshot carries everything needed to recalibrate
			local w = sw * 0.35
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, 0, top, w, 1, { 0.2, 1, 0.2 }, 0.8)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, 0, bot, w, 1, { 1, 0.2, 0.2 }, 0.8)
			GuiColorSetForNextWidget(gui, 1, 1, 0.4, 1)
			GuiText(gui, w + 4, bot - 10, string.format("#%d s=%d H=%d top=%d %s",
				i, s, box_h, box_top, tostring(sfile):gsub(".*/", "")))
		end

		box_top = box_top + box_h + BOX.gap

		local tokens, _, xs = read_deck(wd.e)
		if #tokens > 0 then
			local cfg = read_config(wd.e)
			local sim = wand_structure.simulate(tokens, meta,
				{ spells_per_cast = cfg.spells_per_cast })
			local groups = {} -- all casts together: closes stack per column
			for _, cast in ipairs(sim.casts) do
				collect_delims(cast.nodes, 0, xs, groups)
			end
			draw_delims(gui, groups, sw, top, bot, idc)
		end
	end

	if debug_boxes then
		GuiColorSetForNextWidget(gui, 1, 1, 0.4, 1)
		GuiText(gui, 4, 2, "GUI " .. math.floor(sw + 0.5) .. "x" .. math.floor(sh + 0.5)
			.. "  unit=" .. string.format("%.2f", U * sw))
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
	local show_slots = get("testMod.show_slot_brackets") ~= false
	if not show_panel and not show_slots then return end

	if gui == nil then gui = GuiCreate() end
	GuiStartFrame(gui)
	local sw, sh = GuiGetScreenDimensions(gui)

	if show_slots then -- brackets on every wand box (independent of active wand)
		-- strongly negative z = "bring to front": lower z draws on top, and
		-- this must beat the engine's spell-frame layer, not just our own gui
		GuiZSet(gui, -10)
		draw_box_brackets(gui, sw, sh)
		if DEBUG_RULER then draw_debug(gui, sw, sh) end
		GuiZSet(gui, 1)
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
