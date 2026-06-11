-- Companion "wand structure" panel (Lisp/SLIME-style).
-- When the inventory is open, reads the active wand's cards in slot order plus
-- its gun_config (spells/cast, shuffle), simulates the cast sequence
-- (files/wand_structure.lua), and draws an indented, color-coded tree of each
-- cast's groupings -- including when the wand WRAPS (forced draws past the
-- deck's end pulling cards from the wand's start: the rapid-fire mechanic).
-- The panel docks beside the SELECTED wand's box (below the stack when the
-- boxes leave no room) and is height-clamped to the screen, so it never sits
-- on top of the wand boxes or the slot brackets.
--
-- Loaded once from init.lua; M.update() is called every frame from
-- OnWorldPostUpdate. All drawing uses our own Gui at coordinates we control, so
-- it never depends on the engine's (unexposed) spell-slot positions.

local meta = dofile_once("mods/testMod/files/structure_meta.lua") or {}
local wand_structure = dofile_once("mods/testMod/files/wand_structure.lua")

local M = {}
local gui = nil

-- type -> RGB (0..1) for panel row labels. Brightened from the retired
-- icon-recolor border palette: those values were tuned for icon frames, and
-- as 1px text on the dark nine-piece panel the dark red/blue rows were
-- barely legible (UX review 2026-06-11).
local COLOR = {
	PROJECTILE        = { 1.00, 0.45, 0.45 },
	STATIC_PROJECTILE = { 0.40, 0.92, 0.45 },
	MODIFIER          = { 0.50, 0.65, 1.00 },
	DRAW_MANY         = { 0.95, 0.90, 0.35 },
	MATERIAL          = { 0.95, 0.50, 0.95 },
	UTILITY           = { 0.40, 0.90, 0.90 },
	PASSIVE           = { 1.00, 0.68, 0.28 },
	OTHER             = { 0.78, 0.78, 0.78 },
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
	local cfg = { spells_per_cast = 1, shuffle = false, capacity = 0 }
	if type(ComponentObjectGetValue2) ~= "function" then return cfg end
	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if not ab then return cfg end
	local ok, spc = pcall(ComponentObjectGetValue2, ab, "gun_config", "actions_per_round")
	if ok and tonumber(spc) and tonumber(spc) > 0 then cfg.spells_per_cast = tonumber(spc) end
	local ok2, sh = pcall(ComponentObjectGetValue2, ab, "gun_config", "shuffle_deck_when_empty")
	cfg.shuffle = ok2 and sh == true
	local ok3, cap = pcall(ComponentObjectGetValue2, ab, "gun_config", "deck_capacity")
	if ok3 and tonumber(cap) and tonumber(cap) > 0 then cfg.capacity = tonumber(cap) end
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
		child_colors[#child_colors + 1] = nest_color(depth) -- rainbow even when wrapped
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
	-- min_h/row_off refit 2026-06-09 from 4-box corner probes: the per-box
	-- step is 61.6 GUI (38.5u), not 62.4 -- the old values accumulated ~1.5u
	-- of downward drift by box 4. Fractional units are fine (float math).
	min_h   = 36.5,   -- units: minimum box height (floor)
	h_pad   = 14,     -- units: box height = max(min_h, h_pad + s_scale * sprite_h)
	s_scale = 2,      -- units of box height per wand-sprite pixel
	gap     = 2,      -- units between consecutive boxes
	-- Horizontal-plumb probes confirmed the frames are SQUARE: 17.5 GUI
	-- tall (= the probed width), not 19.2. slot_h shrinks to 10.94u and
	-- row_off grows to 3.7u so the row TOPS stay where the probes put them
	-- (tops fit +-0.7 GUI across all four boxes).
	row_off = 3.7,    -- units: slot-row bottom sits this far above the box bottom
	slot_h  = 10.94,  -- units: card frame height (17.5 GUI, square frame)
	-- Horizontal: nailed by 8 plumb-line probes spanning columns 0..25
	-- (2026-06-09): the layout is in GUI units -- pitch exactly 20.0 GUI
	-- (62.5px), visible frame width 17.5 GUI, col-0 left edge at 26.0 GUI.
	-- All 8 probes fit within 0.15 GUI (the earlier 65px/64px estimates
	-- drifted ~1px+ per column; the "wide boxes compress" theory was false).
	slot0_x = 0.05430, -- first slot frame CENTER: (26.0 + 8.75)/640
	pitch   = 0.03125, -- slot-to-slot spacing: 20.0 GUI / 640
	halfw   = 0.01367, -- half VISIBLE frame width: 8.75 GUI / 640
	-- Multi-row: the machinery below supports wands whose slot row wraps,
	-- but a capacity-26 wand renders as ONE long row at 2000x1125 (user
	-- observation) -- so wrapping is either resolution-dependent or doesn't
	-- happen. per_row=99 disables it until someone actually sees a second
	-- row; if that day comes, set per_row to the observed wrap column and
	-- calibrate row_step from the overlay.
	per_row  = 99,    -- slots per displayed row before wrapping (99 = off)
	row_step = 13,    -- units: vertical step between slot rows (unverified)
}
local BAR_W   = 1   -- GUI width of a bracket's vertical bar
local TICK_W  = 3   -- GUI length of the top/bottom hooks
local STACK_X = 1.5 -- horizontal step between closing brackets stacked on one card
local STACK_Y = 1   -- vertical growth per stack level: outer brackets are taller,
                    -- so their hooks wrap around the inner bracket's
-- With the corrected 64px pitch the cell edges (center +- halfw) already sit
-- ~2px outside the visible frame, so no extra nudges are needed.
local CLOSE_NUDGE = 0 -- extra left shift of closing brackets
local OPEN_NUDGE  = 0 -- extra left shift of opening brackets
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
-- cols/rows map deck index -> displayed column / slot-row (multi-row wands
-- wrap their slot row every BOX.per_row slots).
local function collect_delims(nodes, depth, cols, rows, out)
	for _, node in ipairs(nodes) do
		if node.children and #node.children > 0 and node.last then
			local head = node.head or node.first
			local lbl
			if node.kind == "multicast" then
				lbl = "x" .. ((node.group == -1) and "all" or tostring(node.group))
			else
				lbl = "trig " .. tostring(node.payload)
			end
			-- The wrap apparatus (orange ~wrap tag, wrapped-segment brackets,
			-- return line) belongs to the INNERMOST group the wrap happened
			-- in. Ancestors inherit wfirst but must not redraw it -- and they
			-- keep their rainbow color: orange marks the wrap, not the group.
			local wrap_here = node.wfirst ~= nil
			for _, ch in ipairs(node.children) do
				if ch.wfirst and ch.children and #ch.children > 0 then
					wrap_here = false
					break
				end
			end
			out[#out + 1] = {
				ca = cols[head] or (head - 1), -- 0-based slot columns
				cb = cols[node.last] or (node.last - 1),
				ra = rows[head] or 0,          -- 0-based slot rows
				rb = rows[node.last] or 0,
				c = nest_color(depth),
				lbl = lbl,
				-- wrapped-in segment (cards pulled from the wand's start)
				w1 = wrap_here and (cols[node.wfirst] or (node.wfirst - 1)) or nil,
				w2 = wrap_here and (cols[node.wlast] or (node.wlast - 1)) or nil,
				w1r = wrap_here and (rows[node.wfirst] or 0) or nil,
			}
			collect_delims(node.children, depth + 1, cols, rows, out)
		end
	end
end

-- rows_geo[r+1] = { top, bot } for displayed slot-row r (0-based): brackets
-- anchor to the row their card actually sits on.
local function draw_delims(gui, groups, sw, rows_geo, idc)
	local counts, seen = {}, {}
	local function key(g) return g.rb * 100 + g.cb end
	for _, g in ipairs(groups) do counts[key(g)] = (counts[key(g)] or 0) + 1 end
	for _, g in ipairs(groups) do
		local ya = rows_geo[g.ra + 1] or rows_geo[1]
		local yb = rows_geo[g.rb + 1] or rows_geo[1]

		-- open: [ just left of the card, over the slot's left edge, label
		-- above (the ~wrap tag, when present, is appended in wrap orange)
		local lx = sw * (BOX.slot0_x + g.ca * BOX.pitch - BOX.halfw) - OPEN_NUDGE
		bracket(gui, idc, lx, ya.top, ya.bot, 1, g.c)
		GuiColorSetForNextWidget(gui, g.c[1], g.c[2], g.c[3], 1)
		GuiText(gui, lx, ya.top - 9, g.lbl)
		if g.w1 then
			local lw = (GuiGetTextDimensions(gui, g.lbl))
			GuiColorSetForNextWidget(gui, WRAP_COLOR[1], WRAP_COLOR[2], WRAP_COLOR[3], 1)
			GuiText(gui, lx + lw + 2, ya.top - 9, "~wrap")
		end

		-- close: outermost ] ON the card's right edge (s = 0: collected
		-- first, placed rightmost, tallest so its hooks wrap the inner
		-- ones); inner brackets step LEFT over the card art, so the stack
		-- reads inner -> outer left-to-right and stays within the card
		local s = seen[key(g)] or 0
		seen[key(g)] = s + 1
		local grow = (counts[key(g)] - 1 - s) * STACK_Y
		local rx = sw * (BOX.slot0_x + g.cb * BOX.pitch + BOX.halfw)
			- BAR_W - CLOSE_NUDGE - s * STACK_X
		bracket(gui, idc, rx, yb.top - grow, yb.bot + grow, -1, g.c)

		-- wrap: the group continues at the wand's START. Bracket the
		-- wrapped-in segment and draw a carriage-return line, from below the
		-- forward close back (and up, if the wrapped cards sit on an earlier
		-- slot row) to the wrapped segment's [.
		-- Always WRAP orange: orange marks the wrap, rainbow marks groups.
		if g.w1 then
			local yw = rows_geo[(g.w1r or 0) + 1] or rows_geo[1]
			local wlx = sw * (BOX.slot0_x + g.w1 * BOX.pitch - BOX.halfw) - OPEN_NUDGE
			local wrx = sw * (BOX.slot0_x + g.w2 * BOX.pitch + BOX.halfw)
				- BAR_W - CLOSE_NUDGE
			bracket(gui, idc, wlx, yw.top, yw.bot, 1, WRAP_COLOR)
			bracket(gui, idc, wrx, yw.top, yw.bot, -1, WRAP_COLOR)
			local ry = yb.bot + grow + 2 -- return line sits just below the close's row
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx, yb.bot + grow, 1, ry - (yb.bot + grow) + 1, WRAP_COLOR)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, wlx, ry, rx - wlx, 1, WRAP_COLOR)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, wlx, yw.bot, 1, ry - yw.bot + 1, WRAP_COLOR)
		end
	end
end

-- ---- calibration HUD (debug_boxes setting) ----------------------------------
-- Everything needed to nail the geometry from ONE screenshot:
--  * GUI-coordinate rulers (lines every 50 GUI, ticks every 10, labeled)
--  * the live BOX constants that produced the frame (self-documenting)
--  * live mouse position: raw (InputGetMousePosOnScreen) + a candidate GUI
--    conversion, with a crosshair drawn at the converted spot -- if the
--    crosshair sits under your cursor, the conversion is right
--  * MIDDLE-CLICK probe recorder: hover a landmark (e.g. a card's exact
--    corner), middle-click, and the point is logged on screen (last 8)
--  * RIGHT-CLICK plumb lines: drops a full-height vertical line at the
--    cursor's x, labeled with the GUI x -- align it against slot edges
--    across every box at once to read pitch/origin directly (last 8)
--  * SHIFT+RIGHT-CLICK: horizontal plumb line at the cursor's y, labeled
--    -- align against slot-row tops/bottoms across boxes (last 8)
local probes = {}
local vlines = {}
local hlines = {}

local function draw_calibration_hud(gui, sw, sh, idc)
	-- rulers
	for gx = 0, math.floor(sw), 10 do
		local major = (gx % 50 == 0)
		idc.n = idc.n + 1
		line(gui, 70000 + idc.n, gx, 0, 1, major and sh or 4, { 0.3, 0.6, 1 }, major and 0.25 or 0.8)
		if major then
			GuiColorSetForNextWidget(gui, 0.3, 0.6, 1, 1)
			GuiText(gui, gx + 1, 10, tostring(gx))
		end
	end
	for gy = 0, math.floor(sh), 10 do
		local major = (gy % 50 == 0)
		idc.n = idc.n + 1
		line(gui, 70000 + idc.n, 0, gy, major and sw or 4, 1, { 0.3, 1, 0.4 }, major and 0.25 or 0.8)
		if major then
			GuiColorSetForNextWidget(gui, 0.3, 1, 0.4, 1)
			GuiText(gui, 24, gy + 1, tostring(gy))
		end
	end

	-- constants dump + dims (leave room for up to 8 probe lines below)
	local y = sh - 130
	local function say(text)
		GuiColorSetForNextWidget(gui, 1, 1, 0.4, 1)
		GuiText(gui, 4, y, text)
		y = y + 10
	end
	say(string.format("GUI %dx%d  unit=%.2fgui (%.3f of w)",
		math.floor(sw + 0.5), math.floor(sh + 0.5), U * sw, U))
	say(string.format("BOX top0=%g min_h=%g h_pad=%g s_scale=%g gap=%g row_off=%g slot_h=%g",
		BOX.top0, BOX.min_h, BOX.h_pad, BOX.s_scale, BOX.gap, BOX.row_off, BOX.slot_h))
	say(string.format("X: slot0_x=%.4f (%.1fgui) pitch=%.4f (%.1fgui) halfw=%.4f (%.1fgui) nudges o=%g c=%g",
		BOX.slot0_x, BOX.slot0_x * sw, BOX.pitch, BOX.pitch * sw,
		BOX.halfw, BOX.halfw * sw, OPEN_NUDGE, CLOSE_NUDGE))

	-- mouse + probes
	if type(InputGetMousePosOnScreen) == "function" then
		local ok, mx, my = pcall(InputGetMousePosOnScreen)
		if ok and mx then
			-- raw is in the 1280x720 virtual screen = exactly 2x GUI
			-- (verified by probes against known slot corners, 2026-06-09)
			local cx, cy = mx * sw / 1280, my * sh / 720
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, cx - 6, cy, 13, 1, { 1, 0.3, 1 }, 0.9)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, cx, cy - 6, 1, 13, { 1, 0.3, 1 }, 0.9)
			say(string.format("mouse raw=(%.0f,%.0f) gui=(%.1f,%.1f)", mx, my, cx, cy))
			local okd, down = pcall(InputIsMouseButtonJustDown, 3) -- middle
			if okd and down then
				probes[#probes + 1] = { mx, my, cx, cy }
				if #probes > 8 then table.remove(probes, 1) end
			end
			local okv, vdown = pcall(InputIsMouseButtonJustDown, 2) -- right
			if okv and vdown then
				local shift = false
				if type(InputIsKeyDown) == "function" then
					local oks, s1 = pcall(InputIsKeyDown, 225) -- Key_LSHIFT
					local oks2, s2 = pcall(InputIsKeyDown, 229) -- Key_RSHIFT
					shift = (oks and s1) or (oks2 and s2) or false
				end
				if shift then
					hlines[#hlines + 1] = { my, cy }
					if #hlines > 8 then table.remove(hlines, 1) end
				else
					vlines[#vlines + 1] = { mx, cx }
					if #vlines > 8 then table.remove(vlines, 1) end
				end
			end
		end
	end

	-- plumb lines: full-height verticals with their GUI x labeled (staggered
	-- so adjacent labels don't overlap)
	for vi, v in ipairs(vlines) do
		idc.n = idc.n + 1; line(gui, 70000 + idc.n, v[2], 0, 1, sh, { 0.4, 1, 1 }, 0.9)
		GuiColorSetForNextWidget(gui, 0.4, 1, 1, 1)
		GuiText(gui, v[2] + 2, 20 + (vi % 4) * 10, string.format("x=%.1f", v[2]))
	end
	-- horizontal plumb lines (shift+right-click), GUI y labeled
	for hi, h in ipairs(hlines) do
		idc.n = idc.n + 1; line(gui, 70000 + idc.n, 0, h[2], sw, 1, { 1, 0.8, 0.3 }, 0.9)
		GuiColorSetForNextWidget(gui, 1, 0.8, 0.3, 1)
		GuiText(gui, sw - 60 - (hi % 4) * 50, h[2] + 1, string.format("y=%.1f", h[2]))
	end
	for pi, p in ipairs(probes) do
		say(string.format("probe %d: raw=(%.0f,%.0f) gui=(%.1f,%.1f)", pi, p[1], p[2], p[3], p[4]))
		-- persistent marker AT the probed point, so the screenshot shows
		-- exactly where each probe landed relative to the intended corner
		idc.n = idc.n + 1; line(gui, 70000 + idc.n, p[3] - 3, p[4], 7, 1, { 1, 1, 0.2 }, 1)
		idc.n = idc.n + 1; line(gui, 70000 + idc.n, p[3], p[4] - 3, 1, 7, { 1, 1, 0.2 }, 1)
		GuiColorSetForNextWidget(gui, 1, 1, 0.2, 1)
		GuiText(gui, p[3] + 3, p[4] + 2, tostring(pi))
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

-- Measure every carried wand's box (quick-slot order): the stacking model plus
-- each wand's deck, config, sprite and slot-row geometry. One shared pass --
-- the slot brackets render from it, and the panel docks against it (the
-- selected wand's box top + the stack's bottom/right extents).
-- Returns wands, stack bottom (GUI y) and stack right edge (GUI x).
local function collect_wand_boxes(gui, sw)
	local players = EntityGetWithTag("player_unit")
	if not players or #players == 0 then return {}, BOX.top0 * U * sw, 0 end
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

	local box_top = BOX.top0 -- units; boxes stack, each as tall as its wand needs
	local right = 0
	for _, wd in ipairs(wands) do
		wd.tokens, wd.always, wd.xs = read_deck(wd.e)
		wd.cfg = read_config(wd.e)
		wd.s, wd.sfile = wand_sprite_h(gui, wd.e)
		wd.sim = wand_structure.simulate(wd.tokens, meta,
			{ spells_per_cast = wd.cfg.spells_per_cast })

		-- displayed slot rows: capacity wraps every per_row slots (fall back
		-- to the highest occupied slot if the capacity read failed)
		local max_slot = wd.cfg.capacity - 1
		for _, x in ipairs(wd.xs) do if x > max_slot then max_slot = x end end
		wd.nrows = math.max(1, math.floor(max_slot / BOX.per_row) + 1)

		wd.box_h = math.max(BOX.min_h, BOX.h_pad + BOX.s_scale * wd.s)
			+ (wd.nrows - 1) * BOX.row_step
		wd.top = box_top
		-- the LAST slot row sits row_off above the box bottom; earlier rows
		-- stack upward by row_step
		wd.rows_geo = {}
		for r = 0, wd.nrows - 1 do
			local bot = (box_top + wd.box_h - BOX.row_off
				- (wd.nrows - 1 - r) * BOX.row_step) * U * sw
			wd.rows_geo[r + 1] = { top = bot - BOX.slot_h * U * sw, bot = bot }
		end

		-- box right edge: last slot's frame edge + ~5 GUI of box border
		-- (col-0 frame left sits at 26 GUI, box left at ~21)
		if max_slot >= 0 then
			local last_col = math.min(max_slot, BOX.per_row - 1)
			local er = sw * (BOX.slot0_x + last_col * BOX.pitch + BOX.halfw) + 5
			if er > right then right = er end
		end

		box_top = box_top + wd.box_h + BOX.gap
	end
	return wands, box_top * U * sw, right
end

-- Delimit each measured wand box's spell row.
local function draw_box_brackets(gui, sw, sh, wands)
	local debug_boxes = type(ModSettingGet) == "function"
		and ModSettingGet("testMod.debug_boxes") == true

	local idc = { n = 0 }
	for i, wd in ipairs(wands) do
		if debug_boxes then
			local w = sw * 0.35
			for r, geo in ipairs(wd.rows_geo) do
				-- computed slot-row top (green) / bottom (red) per row
				idc.n = idc.n + 1; line(gui, 70000 + idc.n, 0, geo.top, w, 1, { 0.2, 1, 0.2 }, 0.8)
				idc.n = idc.n + 1; line(gui, 70000 + idc.n, 0, geo.bot, w, 1, { 1, 0.2, 0.2 }, 0.8)
				-- per-column computed frame edges, full row height (green =
				-- left, red = right): pitch/origin error shows as these lines
				-- walking off the real card edges as the column index grows
				for col = 0, BOX.per_row - 1 do
					local exl = sw * (BOX.slot0_x + col * BOX.pitch - BOX.halfw)
					local exr = sw * (BOX.slot0_x + col * BOX.pitch + BOX.halfw)
					idc.n = idc.n + 1; line(gui, 70000 + idc.n, exl, geo.top, 1, geo.bot - geo.top, { 0.2, 1, 0.2 }, 0.55)
					idc.n = idc.n + 1; line(gui, 70000 + idc.n, exr - 1, geo.top, 1, geo.bot - geo.top, { 1, 0.2, 0.2 }, 0.55)
					if i == 1 and r == 1 and col % 2 == 0 then -- column indices once
						GuiColorSetForNextWidget(gui, 0.6, 0.8, 1, 1)
						GuiText(gui, exl + 2, geo.top - 18, tostring(col))
					end
				end
			end
			GuiColorSetForNextWidget(gui, 1, 1, 0.4, 1)
			GuiText(gui, w + 4, wd.rows_geo[1].bot - 10, string.format(
				"#%d s=%d H=%d top=%du cap=%d rows=%d row1[%.1f..%.1f]gui %s",
				i, wd.s, wd.box_h, wd.top, wd.cfg.capacity, wd.nrows,
				wd.rows_geo[1].top, wd.rows_geo[1].bot, tostring(wd.sfile):gsub(".*/", "")))
		end

		if #wd.tokens > 0 then
			-- displayed position of each card: wraps every per_row slots
			local cols, rows = {}, {}
			for k, x in ipairs(wd.xs) do
				cols[k] = x % BOX.per_row
				rows[k] = math.floor(x / BOX.per_row)
			end
			local groups = {} -- all casts together: closes stack per row+column
			for _, cast in ipairs(wd.sim.casts) do
				collect_delims(cast.nodes, 0, cols, rows, groups)
			end
			draw_delims(gui, groups, sw, wd.rows_geo, idc)
		end
	end

	if debug_boxes then
		draw_calibration_hud(gui, sw, sh, idc)
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

-- ---- companion structure panel (docked to the selected wand) ----------------

-- The panel describes the HELD wand (= the selected box), so it stays put
-- while the user rearranges that wand's spells and live-updates as the cast
-- order changes -- no popping like a hover tooltip would. It docks right of
-- the wand-box stack, top-aligned with the selected wand's own box; when the
-- boxes leave no room beside them (a capacity-26 box spans nearly the whole
-- screen) it falls back to centered below the stack. Height is clamped to the
-- screen; overflow folds into one "... +N more" line. Either way it never
-- covers a wand box, so the old z-order fight with the engine's spell frames
-- and our slot brackets can't happen.
local DOCK_GAP     = 6  -- GUI between the boxes and the docked panel
local RIGHT_KEEPOUT = 64 -- GUI kept clear of the right-side HUD column
local function draw_panel(gui, rows, title, sw, sh, anchor)
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
	local px, y0
	if anchor.dock_x + panel_w <= sw - RIGHT_KEEPOUT then
		px, y0 = math.floor(anchor.dock_x), math.floor(anchor.dock_y)
	else
		px = math.floor((sw - panel_w) / 2)
		y0 = math.floor(anchor.below_y)
	end

	-- clamp to the screen: keep the rows that fit, fold the rest
	local max_rows = math.floor((sh - 6 - y0 - pad - 2 - line_h) / line_h)
	if max_rows < 2 then max_rows = 2 end
	if #rows > max_rows then
		local kept = {}
		for i = 1, max_rows - 1 do kept[i] = rows[i] end
		kept[max_rows] = { bars = {},
			label = "... +" .. (#rows - max_rows + 1) .. " more",
			color = HEADER_COLOR }
		rows = kept
	end

	local panel_h = (#rows + 1) * line_h + pad * 2

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
	if not wand_structure then return end

	-- Once the gui exists it must start a frame EVERY update, even with the
	-- inventory closed: the engine keeps the previous frame's widgets live
	-- (mouse-capturing) until the next GuiStartFrame, so skipping frames left
	-- our widgets blocking wand fire after the inventory was closed.
	if gui == nil then gui = GuiCreate() end
	GuiStartFrame(gui)
	-- Never capture the mouse: hovering the panel/brackets must not block
	-- firing or inventory clicks. 2 = GUI_OPTION.NonInteractive
	-- (data/scripts/lib/utilities.lua); options reset on each GuiStartFrame,
	-- so re-add every frame.
	GuiOptionsAdd(gui, 2)

	if type(GameIsInventoryOpen) ~= "function" or not GameIsInventoryOpen() then return end

	local get = (type(ModSettingGet) == "function") and ModSettingGet or function() return nil end
	local show_panel = get("testMod.show_grouping") ~= false
	local show_slots = get("testMod.show_slot_brackets") ~= false
	if not show_panel and not show_slots then return end

	local sw, sh = GuiGetScreenDimensions(gui)

	-- one measure/read pass shared by the brackets and the panel's dock anchor
	local boxes, stack_bot, stack_right = collect_wand_boxes(gui, sw)

	if show_slots then -- brackets on every wand box (independent of active wand)
		-- strongly negative z = "bring to front": lower z draws on top, and
		-- this must beat the engine's spell-frame layer, not just our own gui
		GuiZSet(gui, -10)
		draw_box_brackets(gui, sw, sh, boxes)
		if DEBUG_RULER then draw_debug(gui, sw, sh) end
		GuiZSet(gui, 1)
	end

	if show_panel then -- companion cast-structure tree for the active/held wand
		local wand = get_active_wand()
		local wd = nil
		for _, b in ipairs(boxes) do
			if b.e == wand then wd = b; break end
		end
		if wd and (#wd.tokens > 0 or #wd.always > 0) then
			-- Shuffle wands randomize draw order at cast time, so the
			-- slot-order simulation is only one possible outcome.
			local title = "Wand structure  (" .. wd.cfg.spells_per_cast .. "/cast)"
			if wd.cfg.shuffle then
				title = "Wand structure  (" .. wd.cfg.spells_per_cast
					.. "/cast, shuffle: order varies!)"
			end
			local anchor = {
				dock_x  = stack_right + DOCK_GAP,
				dock_y  = wd.top * U * sw,
				below_y = stack_bot + DOCK_GAP,
			}
			draw_panel(gui, sim_rows(wd.sim, wd.cfg, wd.always), title, sw, sh, anchor)
		end
	end
end

return M
