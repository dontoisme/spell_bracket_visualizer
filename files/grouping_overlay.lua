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

local meta = dofile_once("mods/spell_bracket_visualizer/files/structure_meta.lua") or {}
local sprite_wh_meta = dofile_once("mods/spell_bracket_visualizer/files/wand_sprite_meta.lua") or {}
local wand_structure = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")

local M = {}
local gui = nil

-- Shown in the debug info box so a bug-report screenshot self-identifies the
-- build. Bump on each Workshop release.
local VERSION = "v1.2.1"

-- Panel text size, chosen by the panel_text_size mod setting (enum ids).
local PANEL_SCALE_MAP = { tiny = 0.5, small = 0.6, medium = 0.75 }

-- Calibration measuring tool (debug): middle-click drops a point, a second drops
-- the other end and draws the measured span; a third starts a fresh pair. Lets
-- us read a slot corner's exact GUI coords and the pitch/row-height between two
-- corners -- the only way to pin engine-drawn geometry we can't query (see the
-- data.wak scan: the inventory UI is engine C++, no Lua slot positions exist).
local measure_pts = {}

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
				-- verified in-game 2026-06-11 ("always: Bounce" wand); pcall
				-- kept so a future API change degrades to "not always-cast"
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
	-- no "xN" / "(trig N)" suffixes (user calls, 2026-06-11): the spell name
	-- already says it and the indented children below show what was gathered
	-- or carried as payload
	local label = mods .. name
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
local PIXEL = "mods/spell_bracket_visualizer/files/ui/pixel.png"
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
	top0    = 30,   -- units: top of wand box 1 (anchor; measure-confirmed dead-on)
	gap     = 2.9,  -- units: inter-box gap (box bottom -> next box top). A plain
	                -- constant -- ALL sprite-driven height now lives in box_h
	                -- (= row_offset + below_c, below), so there is no min_h floor
	                -- and no STEP to keep in sync; the per-box step just varies
	                -- with the sprite. tools/test_box_geometry.py guards box_h.
	-- Big-art boxes (2026-06-12, supersedes v8's "2u per px of art HEIGHT"):
	-- the header draws the wand rotated 45 deg, so what grows the box is the
	-- art's DIAGONAL bbox D = 0.7071*(w+h) -- pixel-proven by wand_0430.png
	-- (14x9: only 9px tall yet its box sits over floor). 2026-06-16 (v3 LINEAR):
	-- three Measure-tool samples on one stack -- D=12.0 -> row-offset 19.38u,
	-- D=14.1 -> 21.88u, D=22.6 -> 28.13u -- form a straight LINE, NOT a flat
	-- floor + slope. The old "flat below a threshold" law could only be right
	-- near one D (it fit ~D14 by luck); D=12 sat ~2.5u too low and D=22.6 ~6u
	-- too high. So the slot-row offset is LINEAR in D with no floor:
	--   row_offset = row_a + row_b * D     (fits all three within 0.5u).
	-- BOX HEIGHT is then a dead-constant below_c BELOW the row top -- box-bottom
	-- vs row-top measured 14.97/14.97/15.03u across D=12/14.1/22.6 (2026-06-16),
	-- so box_h = row_offset + below_c, NO min_h floor (the D=12 box is actually
	-- ~34.4u, under the old 35.6 "floor"). This is what fixed the residual
	-- cascade: box_h had been ~1.6u too small on big wands, sinking the boxes
	-- below. Calibrated on D 12-22.6; a D>=27 sample would extend it up-range.
	-- (Superseded the diag_floor/diag_box_slope/diag_row_slope + min_h model.)
	row_a   = 10.15, -- units: slot-row offset (box top -> row top) at D=0 (intercept)
	row_b   = 0.80,  -- units: row-offset growth per unit of D = 0.7071*(w+h)
	below_c = 15.0,  -- units: box bottom sits this far below the row top (measured)
	-- Frames were thought SQUARE at 17.5 GUI, but the 2026-06-15 measure-tool
	-- probe read the slot row at 15.0 GUI tall. slot_h dropped to match; row_off
	-- raised in step so the row TOP holds at the measured box-top offset
	-- (~34 GUI = 21.1u; floor wands probed 33-35 GUI offset, slot 15 GUI tall).
	row_off = 4.0,    -- units: slot-row bottom sits this far above the box bottom;
	                  -- = base offset 35.6 GUI (box top -> slot-row top). Raised
	                  -- with the min_h drop so the row absolute position holds.
	slot_h  = 9.375,  -- units: card frame height (15.0 GUI tall)
	-- Horizontal: nailed by 8 plumb-line probes spanning columns 0..25
	-- (2026-06-09): the layout is in GUI units -- pitch exactly 20.0 GUI
	-- (62.5px), visible frame width 17.5 GUI, col-0 left edge at 26.0 GUI.
	-- All 8 probes fit within 0.15 GUI (the earlier 65px/64px estimates
	-- drifted ~1px+ per column; the "wide boxes compress" theory was false).
	slot0_x = 0.05430, -- first slot frame CENTER: (26.0 + 8.75)/640
	pitch   = 0.03125, -- slot-to-slot spacing: 20.0 GUI / 640
	halfw   = 0.01367, -- half VISIBLE frame width: 8.75 GUI / 640
	-- A box is never narrower than its header (wand sprite + the Shuffle /
	-- Spells per Cast columns): right edge >= 164.5 GUI even for a 1-slot
	-- wand (measured from a screenshot 2026-06-11 -- the panel used to dock
	-- INSIDE the starting wands' boxes). Box width = max(this, slot row).
	min_right = 0.25703, -- 164.5 GUI / 640
	-- Multi-row: the machinery below supports wands whose slot row wraps. The
	-- wrap column is now computed per-frame from the screen aspect by
	-- wrap_columns() (a capacity-26 wand is ONE row at 16:9 but wraps on
	-- narrower aspects). This per_row is only the FALLBACK passed when the
	-- aspect is >= 16:9 (99 = no wrap); row_step is still unverified -- if a
	-- real second row appears, calibrate it from the debug box / a screenshot.
	per_row  = 99,    -- fallback wrap column for >= 16:9 (99 = off; see wrap_columns)
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
local BRACKET_RAISE = 0 -- GUI: extra lift of all bracket glyphs above the
                        -- slot row. Was 2 (tuned 2026-06-11) -- but that
                        -- tuning compensated the then-broken box geometry;
                        -- with the diagonal-bbox model placing rows
                        -- engine-exact, the user chose FLUSH (2026-06-12).

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
-- can be placed: the INNERMOST sits on the card's right edge and outer ones
-- step right into the slot gap (inner -> outer still reads left -> right,
-- like nested parens on paper). Parents are collected before their children,
-- so per column the collection order is outer -> inner.
-- The span starts at the group's OWN card (node.head): leading modifiers sit
-- outside the parens, Lisp-style, matching the panel's "[mods] name" layout.
-- `xs` maps deck index -> real slot column (handles empty slots in the wand).
-- cols/rows map deck index -> displayed column / slot-row (multi-row wands
-- wrap their slot row every BOX.per_row slots).
local function collect_delims(nodes, depth, cols, rows, out)
	for _, node in ipairs(nodes) do
		if node.children and #node.children > 0 and node.last then
			local head = node.head or node.first
			-- Brackets carry NO text labels (user calls, 2026-06-11): the
			-- card art already says x2/x3, a trigger's payload shows as the
			-- nested bracket, and the labels collided ("trig 1x3"). Only
			-- the orange ~wrap tag remains.
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

		-- open: [ just left of the card, raised so its top hook overlaps the
		-- slot's top edge (the ~wrap tag, when present, sits above in orange)
		local lx = sw * (BOX.slot0_x + g.ca * BOX.pitch - BOX.halfw) - OPEN_NUDGE
		bracket(gui, idc, lx, ya.top - BRACKET_RAISE, ya.bot - BRACKET_RAISE, 1, g.c)
		if g.w1 then
			-- "wraps to front": reads toward the orange segment at the wand's
			-- start (was "~wrap", but Noita's font renders ~ as a double
			-- quote). Sits clear above the raised bracket's hook level
			-- (screenshot-tuned: -9 and -10 still touched the hooks).
			GuiColorSetForNextWidget(gui, WRAP_COLOR[1], WRAP_COLOR[2], WRAP_COLOR[3], 1)
			GuiText(gui, lx, ya.top - 11, "wraps to front")
		end

		-- close: innermost ] sits ON the card's right edge and outer
		-- brackets step RIGHT into the slot gap (outermost furthest out
		-- and tallest, its hooks wrapping the inner ones) -- closes start
		-- at the end of the slot and never push into the card art (user
		-- call 2026-06-11; they used to step left over the card)
		local s = seen[key(g)] or 0
		seen[key(g)] = s + 1
		local o = counts[key(g)] - 1 - s -- 0 = innermost (collected last)
		local grow = o * STACK_Y
		local rx = sw * (BOX.slot0_x + g.cb * BOX.pitch + BOX.halfw)
			- BAR_W - CLOSE_NUDGE + o * STACK_X
		bracket(gui, idc, rx, yb.top - grow - BRACKET_RAISE,
			yb.bot + grow - BRACKET_RAISE, -1, g.c)

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
			bracket(gui, idc, wlx, yw.top - BRACKET_RAISE, yw.bot - BRACKET_RAISE, 1, WRAP_COLOR)
			bracket(gui, idc, wrx, yw.top - BRACKET_RAISE, yw.bot - BRACKET_RAISE, -1, WRAP_COLOR)
			local ry = yb.bot + grow + 2 -- return line sits just below the close's row
			-- drop from the (raised) forward close's bottom down to the return line
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, rx, yb.bot + grow - BRACKET_RAISE, 1,
				ry - (yb.bot + grow - BRACKET_RAISE) + 1, WRAP_COLOR)
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, wlx, ry, rx - wlx, 1, WRAP_COLOR)
			-- riser meets the (raised) wrapped-segment open bracket's bottom
			idc.n = idc.n + 1; line(gui, 70000 + idc.n, wlx, yw.bot - BRACKET_RAISE, 1,
				ry - (yw.bot - BRACKET_RAISE) + 1, WRAP_COLOR)
		end
	end
end

-- Read this wand's art WIDTH+HEIGHT in px (drives the diagonal-bbox box
-- model; vanilla art is 3..29 px a side). Vanilla paths resolve through the
-- PREGENERATED table (wand_sprite_meta.lua); the live GuiGetImageDimensions
-- read is the fallback for modded wands. The starting wands' image_file is
-- a sprite XML (handgun.xml) -- the table carries those too
-- (frame_width+frame_height). A failed read returns 18 (handgun-sized:
-- comfortably below the floor threshold, like most wands).
-- Per-sprite geometry overrides (reactive escape hatch). A few wands don't fit
-- the diagonal box-height law: the custom sprites (bomb_wand, scepter, skull,
-- ...) and the occasional big procedural wand. When a wand's brackets sit wrong,
-- enable Debug Info and measure two things with the middle-click tool, reading
-- the "(N.NNu)" UNIT value (not the GUI px):
--   box_h   = box outline height  (panel top border -> bottom border)
--   row_top = header offset       (panel top border -> slot-row top)
-- then add an entry keyed by the sprite's image_file path. Overrides win over
-- the computed model; box height stays position-independent, so one entry fixes
-- that wand in every slot. (For reference: a floor wand is box_h ~35.6,
-- row_top ~22.2.) Leave empty until a specific wand actually misbehaves.
local SPRITE_OVERRIDES = {
	-- ["data/items_gfx/bomb_wand.png"] = { box_h = 35.6, row_top = 22.2 },
}

-- Returns the wand art's w+h (drives the box-height model) AND its sprite path
-- (used to look up SPRITE_OVERRIDES). Path is nil when unreadable.
local function wand_art_wh(gui, wand)
	local sc = EntityGetFirstComponentIncludingDisabled(wand, "SpriteComponent")
	if sc then
		local ok, f = pcall(ComponentGetValue2, sc, "image_file")
		if ok and type(f) == "string" and f ~= "" then
			if sprite_wh_meta[f] then return sprite_wh_meta[f], f end
			local ok2, w, h = pcall(GuiGetImageDimensions, gui, f, 1)
			if ok2 and tonumber(w) and tonumber(h)
				and w > 0 and w < 30 and h > 0 and h < 30 then
				return w + h, f
			end
		end
	end
	-- image_file unreadable or unknown: vanilla wands carry the same art
	-- path on their AbilityComponent (SetWandSprite sets both)
	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if ab then
		local ok, f = pcall(ComponentGetValue2, ab, "sprite_file")
		if ok and type(f) == "string" and sprite_wh_meta[f] then
			return sprite_wh_meta[f], f
		end
	end
	return 18, nil
end

-- Measure every carried wand's box (quick-slot order): the stacking model plus
-- each wand's deck, config, sprite and slot-row geometry. One shared pass --
-- the slot brackets render from it, and the panel docks against it (the
-- selected wand's box top + the stack's bottom/right extents).
-- Returns wands, stack bottom (GUI y) and stack right edge (GUI x).
-- Self-calibrating wrap column (2026-06-15). Noita keeps the GUI HEIGHT fixed
-- and grows WIDTH with the screen aspect, laying out spell slots in absolute GUI
-- units -- so an aspect NARROWER than 16:9 fits fewer slots per row before the
-- engine wraps the row. Our slot geometry (slot0_x/pitch/halfw) is a fraction of
-- width measured at 16:9; converting "columns that fit" to the live aspect needs
-- only the RATIO aspect/CAL_ASPECT -- not the absolute GUI width (which the
-- debug box reports, but we never have to assume).
--   16:9 and WIDER  -> keep the shipped no-wrap behavior (return 99): the
--                      released 16:9 build is validated and wider only adds room.
--   NARROWER        -> compute the wrap column so the brackets follow the row.
-- WRAP_EDGE is the fraction of the live width the engine wraps at (~1 = right
-- screen edge). If a narrow-aspect screenshot shows the wrap one column off,
-- nudge WRAP_EDGE (aspect + observed wrap column are both in the debug box).
local CAL_ASPECT = 16 / 9
local WRAP_EDGE  = 1.0
local function wrap_columns(sw, sh)
	local aspect = (sh > 0) and (sw / sh) or CAL_ASPECT
	if aspect >= CAL_ASPECT - 0.01 then return 99 end
	local c_max = math.floor(
		(WRAP_EDGE * aspect / CAL_ASPECT - BOX.slot0_x - BOX.halfw) / BOX.pitch)
	return math.max(1, c_max + 1)
end

local function collect_wand_boxes(gui, sw, per_row)
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
	for _, wd in ipairs(wands) do
		wd.tokens, wd.always, wd.xs = read_deck(wd.e)
		wd.cfg = read_config(wd.e)
		wd.wh, wd.sprite = wand_art_wh(gui, wd.e)
		wd.sim = wand_structure.simulate(wd.tokens, meta,
			{ spells_per_cast = wd.cfg.spells_per_cast })

		-- displayed slot rows: capacity wraps every per_row slots (fall back
		-- to the highest occupied slot if the capacity read failed). per_row is
		-- the aspect-calibrated wrap column (wrap_columns); stamped on the box so
		-- the brackets and the debug readout use the same value.
		wd.per_row = per_row
		local max_slot = wd.cfg.capacity - 1
		for _, x in ipairs(wd.xs) do if x > max_slot then max_slot = x end end
		wd.nrows = math.max(1, math.floor(max_slot / per_row) + 1)

		-- Both the slot-row offset AND the box height grow LINEARLY with the
		-- rotated-art diagonal D = 0.7071*(w+h): row_offset = row_a + row_b*D, and
		-- the box bottom is a constant below_c beneath the row top, so
		-- box_h = row_offset + below_c (no floor; see the BOX comments). Getting
		-- box_h right is what stops the downward stacking cascade.
		-- Extra rows of a multi-row wand (per_row, frozen feature) stack DOWN.
		-- A per-sprite override wins over the model (SPRITE_OVERRIDES).
		local ov = wd.sprite and SPRITE_OVERRIDES[wd.sprite]
		local D = 0.7071 * wd.wh
		local row_offset = (ov and ov.row_top) or (BOX.row_a + BOX.row_b * D)
		wd.box_h = ((ov and ov.box_h) or (row_offset + BOX.below_c))
			+ (wd.nrows - 1) * BOX.row_step
		wd.top = box_top
		local row_top_u = box_top + row_offset
		wd.rows_geo = {}
		for r = 0, wd.nrows - 1 do
			local top = (row_top_u + r * BOX.row_step) * U * sw
			wd.rows_geo[r + 1] = { top = top, bot = top + BOX.slot_h * U * sw }
		end

		-- box right edge (GUI): the wider of the box's minimum (header-
		-- driven, BOX.min_right) and the slot row (last slot's frame edge
		-- + ~5 GUI of border; col-0 frame left sits at 26 GUI, box at ~21)
		wd.right = sw * BOX.min_right
		if max_slot >= 0 then
			local last_col = math.min(max_slot, per_row - 1)
			wd.right = math.max(wd.right,
				sw * (BOX.slot0_x + last_col * BOX.pitch + BOX.halfw) + 5)
		end

		box_top = box_top + wd.box_h + BOX.gap
	end
	return wands, box_top * U * sw
end

-- Delimit each measured wand box's spell row.
-- (The "Calibration Overlay" debug HUD that used to live here -- rulers,
-- plumb lines, click probes, per-box readouts -- was removed for the
-- Workshop release. It lives in git history; re-add it together with its
-- settings.lua entry if the box geometry ever drifts after a game update.)
-- Row-calibration probe, now gated behind the show_debug setting (was a
-- hardcoded constant that shipped =true by accident). Draws the MODEL's
-- computed slot-row top/bottom as 1-GUI magenta lines across every wand box +
-- the wand's art wh / diagonal D. A screenshot of N varied wands gives N exact
-- (D, row-error) samples to refit the box-height law -- which is exactly what's
-- needed when a long/tall wand throws off the stack below it.
local function draw_row_probe(gui, sw, wands)
	for _, wd in ipairs(wands) do
		local r = wd.rows_geo[1]
		-- MAGENTA: the model's estimated slot-ROW top/bottom (bracket position).
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 0.9)
		GuiImage(gui, 90001 + wd.slot * 10, 21, r.top, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 0.9)
		GuiImage(gui, 90002 + wd.slot * 10, 21, r.bot, PIXEL, 0.9, wd.right - 21, 1)
		-- CYAN: the model's estimated BOX top/bottom edges. Compare each to the
		-- engine's actual box outline -- the vertical gap is this box's stacking
		-- error (what drives the cascade). Read it (or Measure it) and report
		-- per box; the label prints the model's box top + height in UNITS.
		local box_top = wd.top * U * sw
		local box_bot = (wd.top + wd.box_h) * U * sw
		GuiColorSetForNextWidget(gui, 0.2, 1, 1, 0.9)
		GuiImage(gui, 90003 + wd.slot * 10, 21, box_top, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 0.2, 1, 1, 0.9)
		GuiImage(gui, 90004 + wd.slot * 10, 21, box_bot, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 0.2, 1, 1, 1)
		GuiText(gui, wd.right + 4, box_top - 4,
			string.format("D=%.1f  box top=%.1fu  h=%.1fu  row+%.1fu",
				0.7071 * wd.wh, wd.top, wd.box_h, r.top / (U * sw) - wd.top))
	end
end

local function draw_box_brackets(gui, sw, wands, show_probe)
	local idc = { n = 0 }
	if show_probe then draw_row_probe(gui, sw, wands) end
	for _, wd in ipairs(wands) do
		-- Shuffle wands get NO brackets (user call 2026-06-11): the deck
		-- order randomizes at cast time, so slot-order grouping painted on
		-- the cards would assert a structure the wand won't honor. The
		-- panel still shows the slot-order tree WITH its "order varies!"
		-- warning -- text can hedge, brackets can't.
		if #wd.tokens > 0 and not wd.cfg.shuffle then
			-- displayed position of each card: wraps every per_row slots
			local cols, rows = {}, {}
			for k, x in ipairs(wd.xs) do
				cols[k] = x % wd.per_row
				rows[k] = math.floor(x / wd.per_row)
			end
			local groups = {} -- all casts together: closes stack per row+column
			for _, cast in ipairs(wd.sim.casts) do
				collect_delims(cast.nodes, 0, cols, rows, groups)
			end
			draw_delims(gui, groups, sw, wd.rows_geo, idc)
		end
	end
end

-- ---- companion structure panel (docked to the selected wand) ----------------

-- The panel describes the HELD wand (= the selected box), so it stays put
-- while the user rearranges that wand's spells and live-updates as the cast
-- order changes -- no popping like a hover tooltip would. It docks in the
-- free column right of the wand boxes, top-aligned with the selected wand's
-- own box when there's room, sliding down past wider boxes / up from the
-- screen bottom when there isn't (see placement below). Height is clamped
-- to the screen; overflow folds into one "... +N more" line. It never
-- covers a wand box, so the old z-order fight with the engine's spell
-- frames and our slot brackets can't happen. (No scroll container on
-- purpose: this gui is NonInteractive so hovering it can never block
-- firing or inventory clicks -- see the fire-block fix.)
local RIGHT_MARGIN    = 3    -- GUI kept clear at the right screen edge
local PANEL_GAP       = 6    -- GUI between the active wand's box edge and the panel
local TOP_BAR_KEEPOUT = 58   -- panel top stays below the HP/mana/gold bars
local BOTTOM_MARGIN   = 12   -- GUI kept clear at the screen bottom
local MAX_PANEL_W     = 220  -- hard cap on panel width (also clamped to sw*0.5)
local PANEL_BG_Z      = -20  -- lower z = front; beats the slot brackets (z -10)
local PANEL_TEXT_Z    = -21  -- one layer in front of the panel background

-- Trim a label with a trailing "..." until it measures within max_px at `scale`.
-- (Labels are ASCII spell names, so #s byte length == char count.)
local function fit_label(gui, text, scale, max_px)
	if max_px <= 0 then return "..." end
	if (GuiGetTextDimensions(gui, text, scale)) <= max_px then return text end
	local s = text
	while #s > 1 and (GuiGetTextDimensions(gui, s .. "...", scale)) > max_px do
		s = s:sub(1, #s - 1)
	end
	return s .. "..."
end

-- Companion cast-structure panel for the held wand, drawn RIGHT-ANCHORED.
-- Overlap with other wands is acceptable (the panel is opaque and topmost), so
-- placement is simple: pin the right edge near the screen edge and grow the
-- panel leftward. Vertically it is HYBRID -- a short structure pins at the
-- selected wand's height (clamped below the HP bars); a long one that won't fit
-- there takes over the full-height right column under the bars (may cover the
-- Wet/Tinker status text, by design). Long labels are truncated to MAX_PANEL_W.
local function draw_panel(gui, rows, title, sw, sh, anchor, scale)
	if #rows == 0 then return end

	local pad = 4
	-- GuiText()/GuiGetTextDimensions() both take a scale arg (verified against
	-- tools_modding/lua_api_documentation.html); measure at the same scale so the
	-- panel width/row height stay exact.
	local _, th = GuiGetTextDimensions(gui, title, scale)
	local line_h = th + 2
	local bar_w = (GuiGetTextDimensions(gui, "| ", scale)) -- advance per nesting spine

	-- width budget: cap at MAX_PANEL_W (and half-screen), AND keep the panel's
	-- LEFT edge clear of the active wand's box right edge so its spell slots stay
	-- clickable (the panel right-anchors and grows leftward). Truncate labels past
	-- the budget, then hug the widest KEPT label. The title is never truncated, so
	-- the panel never collapses even if every label is over-long.
	local sel_right = (anchor.sel and anchor.boxes[anchor.sel])
		and anchor.boxes[anchor.sel].right or 0
	local avail = sw - RIGHT_MARGIN - PANEL_GAP - sel_right
	local max_panel_w = math.min(MAX_PANEL_W, sw * 0.5, avail)
	if max_panel_w < 60 then max_panel_w = 60 end -- floor for a near-full-width active wand
	local max_w = (GuiGetTextDimensions(gui, title, scale))
	for _, r in ipairs(rows) do
		local bars_w = (r.header and 0 or #r.bars) * bar_w
		r.label = fit_label(gui, r.label, scale, max_panel_w - pad * 2 - bars_w)
		local w = bars_w + (GuiGetTextDimensions(gui, r.label, scale))
		if w > max_w then max_w = w end
	end
	local panel_w = max_w + pad * 2

	-- vertical placement (hybrid) --------------------------------------------
	local screen_bot = sh - BOTTOM_MARGIN
	local function rows_at(y, bot)
		return math.floor((bot - y - pad - 2 - line_h) / line_h)
	end
	local stack_top = anchor.boxes[1].top
	for _, b in ipairs(anchor.boxes) do
		if b.top < stack_top then stack_top = b.top end
	end
	local sel_top = (anchor.sel and anchor.boxes[anchor.sel])
		and anchor.boxes[anchor.sel].top or stack_top
	-- candidate top: the selected wand's box top, never above the stack top and
	-- never over the HP/mana/gold bars.
	local cand_top = math.floor(math.max(TOP_BAR_KEEPOUT, stack_top, sel_top))
	local y0
	if rows_at(cand_top, screen_bot) >= #rows then
		y0 = cand_top                    -- short: pin at the wand's height
	else
		y0 = math.floor(TOP_BAR_KEEPOUT) -- long: take over the full-height column
	end
	local bot_limit = screen_bot

	-- right-align: right edge = sw - RIGHT_MARGIN, panel grows leftward
	local px = math.floor(sw - RIGHT_MARGIN - panel_w)
	if px < 4 then px = 4 end

	-- clamp rows to the band: keep what fits, fold the rest into "... +N more"
	local max_rows = math.floor((bot_limit - y0 - pad - 2 - line_h) / line_h)
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

	-- opaque + topmost: lower z draws in front, so the panel sits over any wand
	-- boxes/brackets it overlaps and stays readable.
	GuiZSet(gui, PANEL_BG_Z)
	GuiImageNinePiece(gui, 90210, px - pad, y0 - pad, panel_w, panel_h, 1.0)

	GuiZSet(gui, PANEL_TEXT_Z)
	GuiText(gui, px, y0, title, scale)
	local y = y0 + line_h + 2
	for _, r in ipairs(rows) do
		local x = px
		local bars = r.bars
		if r.header then bars = {} end -- headers sit flush left
		for _, bc in ipairs(bars) do   -- rainbow nesting spines
			GuiColorSetForNextWidget(gui, bc[1], bc[2], bc[3], 1)
			GuiText(gui, x, y, "|", scale)
			x = x + bar_w
		end
		GuiColorSetForNextWidget(gui, r.color[1], r.color[2], r.color[3], 1)
		GuiText(gui, x, y, r.label, scale)
		y = y + line_h
	end
	GuiZSet(gui, 1)
end

-- ---- debug info box (lightweight, user-facing) -----------------------------

-- A small top-left panel a player can flip on in settings and screenshot when
-- reporting a layout bug. It carries the exact facts we need to reproduce:
-- the virtual GUI dimensions + aspect (resolution/aspect is what actually
-- moves the wand-slot layout -- see the BOX.per_row note) and the held wand's
-- size. NOT the heavy calibration HUD (rulers/probes) -- that lives in git
-- history for dev recalibration; this is the one ordinary users turn on.
local function draw_debug_info(gui, sw, sh, wd, per_row)
	local lines = { "Spell Bracket Visualizer " .. VERSION .. "  (debug)" }

	local aspect = (sh > 0) and (sw / sh) or 0
	local off_169 = math.abs(aspect - 16 / 9) > 0.02
	lines[#lines + 1] = string.format("GUI  %d x %d   aspect %.3f  %s",
		math.floor(sw + 0.5), math.floor(sh + 0.5), aspect,
		off_169 and "(NOT 16:9 -- layout calibrated for 16:9)" or "(16:9)")
	lines[#lines + 1] = "slot-row wraps at col: " ..
		((per_row and per_row < 99) and tostring(per_row) or "off (>= 16:9)")

	if wd then
		lines[#lines + 1] = string.format(
			"wand:  cap=%d  spells=%d  per-cast=%d  shuffle=%s",
			wd.cfg.capacity, #wd.tokens, wd.cfg.spells_per_cast,
			wd.cfg.shuffle and "yes" or "no")
		lines[#lines + 1] = string.format(
			"rows modeled=%d   cast-wraps=%s",
			wd.nrows, (wd.sim and wd.sim.wrapped) and "yes" or "no")
		-- exact SPRITE_OVERRIDES key for the held wand (copy if it sits wrong)
		lines[#lines + 1] = "sprite: " .. (wd.sprite or "(unknown)")
	else
		lines[#lines + 1] = "wand:  (none held -- select/hold a wand)"
	end
	lines[#lines + 1] = "Reporting a bug? Screenshot this with the wand open."
	lines[#lines + 1] = "Measure: middle-click two points (e.g. slot corners)."

	local line_h, pad = 11, 4
	local max_w = 0
	for _, t in ipairs(lines) do
		local w = (GuiGetTextDimensions(gui, t))
		if w > max_w then max_w = w end
	end
	local panel_w = max_w + pad * 2
	local panel_h = #lines * line_h + pad * 2
	-- top-RIGHT corner: the wand panels you measure sit top-LEFT, so anchor here
	-- to keep the whole left column clear (the HUD it may graze isn't a target)
	local x, y = sw - panel_w - 8, 8

	-- top-left corner is clear of Noita's centered inventory; lower z = front,
	-- so this sits above the panel/boxes (brackets at z=-10 are elsewhere)
	GuiZSet(gui, -7)
	GuiImageNinePiece(gui, 90220, x - pad, y - pad, panel_w, panel_h, 0.9)
	GuiZSet(gui, -8)
	for i, t in ipairs(lines) do
		local c = (i == 1) and HEADER_COLOR
			or (i == 2 and off_169 and WRAP_COLOR)
			or { 1, 1, 1 }
		GuiColorSetForNextWidget(gui, c[1], c[2], c[3], 1)
		GuiText(gui, x, y, t)
		y = y + line_h
	end
	GuiZSet(gui, 1)
end

-- Click-to-measure overlay (only while show_debug). Reads the raw mouse (the
-- engine reports it in a 1280x720 virtual screen = 2x the 640x360 GUI, verified
-- against known slot corners), converts to GUI coords, and lets you drop two
-- points to read the span. Axis split (dx/dy) is reported because slot geometry
-- is axis-aligned: dx as a fraction of width == pitch/slot0 units; dy in U ==
-- row-height units -- i.e. the exact numbers the BOX table is calibrated in.
local function draw_measure(gui, sw, sh)
	if type(InputGetMousePosOnScreen) ~= "function" then return end
	local ok, mx, my = pcall(InputGetMousePosOnScreen)
	if not ok or not mx then return end
	local cx, cy = mx * sw / 1280, my * sh / 720

	local okd, mid = pcall(InputIsMouseButtonJustDown, 3) -- middle: drop a point
	if okd and mid then
		if #measure_pts >= 2 then measure_pts = {} end
		measure_pts[#measure_pts + 1] = { cx, cy }
	end

	local id = 91000
	local function cross(x, y, c, len)
		id = id + 1; line(gui, id, x - len, y, len * 2 + 1, 1, c, 0.9)
		id = id + 1; line(gui, id, x, y - len, 1, len * 2 + 1, c, 0.9)
	end

	GuiZSet(gui, -9)
	cross(cx, cy, { 0.4, 1, 1 }, 6) -- live cursor crosshair
	GuiColorSetForNextWidget(gui, 0.4, 1, 1, 1)
	GuiText(gui, cx + 7, cy + 2, string.format("(%.1f, %.1f)", cx, cy))

	for i, p in ipairs(measure_pts) do
		cross(p[1], p[2], { 1, 1, 0.2 }, 5)
		GuiColorSetForNextWidget(gui, 1, 1, 0.2, 1)
		GuiText(gui, p[1] + 6, p[2] - 12, string.format("P%d (%.1f, %.1f)", i, p[1], p[2]))
	end

	if #measure_pts == 2 then
		local a, b = measure_pts[1], measure_pts[2]
		-- L-guide: horizontal leg at a.y, vertical leg at b.x (slot edges are
		-- axis-aligned, so dx and dy are the meaningful quantities, not a slant)
		id = id + 1; line(gui, id, math.min(a[1], b[1]), a[2],
			math.abs(b[1] - a[1]) + 1, 1, { 1, 0.5, 0.2 }, 0.9)
		id = id + 1; line(gui, id, b[1], math.min(a[2], b[2]),
			1, math.abs(b[2] - a[2]) + 1, { 1, 0.5, 0.2 }, 0.9)
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local dist = math.sqrt(dx * dx + dy * dy)
		GuiColorSetForNextWidget(gui, 1, 0.7, 0.3, 1)
		GuiText(gui, (a[1] + b[1]) / 2 + 4, (a[2] + b[2]) / 2 + 2, string.format(
			"dx=%.1f (%.5fw)  dy=%.1f (%.2fu)  d=%.1f",
			dx, dx / sw, dy, dy / (U * sw), dist))
	end
	GuiZSet(gui, 1)
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
	local show_panel = get("spell_bracket_visualizer.show_grouping") ~= false
	local show_slots = get("spell_bracket_visualizer.show_slot_brackets") ~= false
	local show_debug = get("spell_bracket_visualizer.show_debug") == true
	if not show_panel and not show_slots and not show_debug then return end
	local panel_scale = PANEL_SCALE_MAP[get("spell_bracket_visualizer.panel_text_size") or "small"] or 0.6

	local sw, sh = GuiGetScreenDimensions(gui)

	-- one measure/read pass shared by the brackets and the panel's dock anchor.
	-- per_row is the aspect-calibrated wrap column (99 = no wrap at >= 16:9)
	local per_row = wrap_columns(sw, sh)
	local boxes = collect_wand_boxes(gui, sw, per_row)

	if show_slots then -- brackets on every wand box (independent of active wand)
		-- strongly negative z = "bring to front": lower z draws on top, and
		-- this must beat the engine's spell-frame layer, not just our own gui
		GuiZSet(gui, -10)
		draw_box_brackets(gui, sw, boxes, show_debug)
		GuiZSet(gui, 1)
	end

	if show_panel then -- companion cast-structure tree for the active/held wand
		local wand = get_active_wand()
		local wd, sel = nil, nil
		for i, b in ipairs(boxes) do
			if b.e == wand then wd, sel = b, i; break end
		end
		-- Shuffle wands get nothing at all (user call 2026-06-11): the deck
		-- order randomizes at cast time, so even the panel's slot-order tree
		-- is just one arrangement of many -- not worth showing.
		if wd and not wd.cfg.shuffle and (#wd.tokens > 0 or #wd.always > 0) then
			local title = "Wand structure  (" .. wd.cfg.spells_per_cast .. "/cast)"
			local geo = {} -- per-box GUI geometry: top edge (vertical anchor) + right edge (width clamp)
			for i, b in ipairs(boxes) do
				geo[i] = { top = b.top * U * sw, right = b.right }
			end
			local anchor = {
				boxes = geo,
				sel   = sel,
			}
			draw_panel(gui, sim_rows(wd.sim, wd.cfg, wd.always), title, sw, sh, anchor, panel_scale)
		end
	end

	if show_debug then -- diagnostic readout for bug reports (top-left corner)
		local wand = get_active_wand()
		local dbg_wd = nil
		for _, b in ipairs(boxes) do
			if b.e == wand then dbg_wd = b; break end
		end
		draw_debug_info(gui, sw, sh, dbg_wd, per_row)
		draw_measure(gui, sw, sh)
	end
end

return M
