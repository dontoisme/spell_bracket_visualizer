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
	top0    = 30,     -- units: top of wand box 1
	-- min_h/row_off refit 2026-06-09 from 4-box corner probes: the per-box
	-- step is 61.6 GUI (38.5u), not 62.4 -- the old values accumulated ~1.5u
	-- of downward drift by box 4. Fractional units are fine (float math).
	min_h   = 36.5,   -- units: minimum box height (floor)
	gap     = 2,      -- units between consecutive boxes
	-- Big-art boxes (2026-06-12, supersedes v8's "2u per px of art HEIGHT"):
	-- the header draws the wand rotated 45 deg, so what grows the box is the
	-- art's DIAGONAL bbox D = 0.7071*(w+h) -- pixel-proven by wand_0430.png,
	-- 14x9: only 9px TALL (old law: floor) yet its box is ~2.8u over floor.
	-- Both old "the read fell back to 9" fits matched the same pixels by
	-- coincidence: any art at/below the floor threshold renders identically.
	-- The box grows ~1.6u per D-GUI past the floor threshold, and the slot
	-- row inside drops only ~0.8u per D-GUI -- NOT bottom-anchored; the
	-- rest pads below the row. Fitted to ONE grown sample (D=16.26:
	-- box 39.3u, row +1.44u, both engine-exact) plus two floor wands
	-- (handgun D=12.73, bomb wand D=14.14); the threshold sits between
	-- 14.14 and 16.26 -- 14.5 chosen. Recalibrate on the next big wand.
	diag_floor     = 14.5, -- D (GUI) at/below which the box is floor-height
	diag_box_slope = 1.59, -- u of box height per D-GUI past diag_floor
	diag_row_slope = 0.82, -- u of slot-row drop per D-GUI past diag_floor
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
	-- A box is never narrower than its header (wand sprite + the Shuffle /
	-- Spells per Cast columns): right edge >= 164.5 GUI even for a 1-slot
	-- wand (measured from a screenshot 2026-06-11 -- the panel used to dock
	-- INSIDE the starting wands' boxes). Box width = max(this, slot row).
	min_right = 0.25703, -- 164.5 GUI / 640
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
local function wand_art_wh(gui, wand)
	local sc = EntityGetFirstComponentIncludingDisabled(wand, "SpriteComponent")
	if sc then
		local ok, f = pcall(ComponentGetValue2, sc, "image_file")
		if ok and type(f) == "string" and f ~= "" then
			if sprite_wh_meta[f] then return sprite_wh_meta[f] end
			local ok2, w, h = pcall(GuiGetImageDimensions, gui, f, 1)
			if ok2 and tonumber(w) and tonumber(h)
				and w > 0 and w < 30 and h > 0 and h < 30 then
				return w + h
			end
		end
	end
	-- image_file unreadable or unknown: vanilla wands carry the same art
	-- path on their AbilityComponent (SetWandSprite sets both)
	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if ab then
		local ok, f = pcall(ComponentGetValue2, ab, "sprite_file")
		if ok and type(f) == "string" and sprite_wh_meta[f] then
			return sprite_wh_meta[f]
		end
	end
	return 18
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
	for _, wd in ipairs(wands) do
		wd.tokens, wd.always, wd.xs = read_deck(wd.e)
		wd.cfg = read_config(wd.e)
		wd.wh = wand_art_wh(gui, wd.e)
		wd.sim = wand_structure.simulate(wd.tokens, meta,
			{ spells_per_cast = wd.cfg.spells_per_cast })

		-- displayed slot rows: capacity wraps every per_row slots (fall back
		-- to the highest occupied slot if the capacity read failed)
		local max_slot = wd.cfg.capacity - 1
		for _, x in ipairs(wd.xs) do if x > max_slot then max_slot = x end end
		wd.nrows = math.max(1, math.floor(max_slot / BOX.per_row) + 1)

		-- diagonal growth past the floor threshold (see the BOX comments:
		-- box height and row position grow on DIFFERENT slopes -- the row
		-- is NOT bottom-anchored in a grown box). Extra rows of a
		-- multi-row wand (per_row, frozen feature) stack DOWN from the first.
		local g = math.max(0, 0.7071 * wd.wh - BOX.diag_floor)
		wd.box_h = BOX.min_h + BOX.diag_box_slope * g
			+ (wd.nrows - 1) * BOX.row_step
		wd.top = box_top
		local row_top_u = box_top + (BOX.min_h - BOX.row_off - BOX.slot_h)
			+ BOX.diag_row_slope * g
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
			local last_col = math.min(max_slot, BOX.per_row - 1)
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
-- TEMPORARY (2026-06-12): row-calibration probe. REMOVE BEFORE the next
-- Workshop update. Draws the MODEL's computed slot-row top/bottom as 1-GUI
-- magenta lines across every wand box + the wand's art wh. A screenshot of
-- N varied wands gives N exact (D, row-error) samples to fit e(D) -- the
-- single art-driven drop shared by row position AND box height.
local DEBUG_ROW_PROBE = true

local function draw_row_probe(gui, sw, wands)
	for _, wd in ipairs(wands) do
		local r = wd.rows_geo[1]
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 0.9)
		GuiImage(gui, 90001 + wd.slot * 10, 21, r.top, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 0.9)
		GuiImage(gui, 90002 + wd.slot * 10, 21, r.bot, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 1)
		GuiText(gui, wd.right + 4, r.top - 4,
			string.format("v5 wh=%d D=%.1f", wd.wh, 0.7071 * wd.wh))
	end
end

local function draw_box_brackets(gui, sw, wands)
	local idc = { n = 0 }
	if DEBUG_ROW_PROBE then draw_row_probe(gui, sw, wands) end
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
local DOCK_GAP     = 14 -- GUI between the boxes and the docked panel
local RIGHT_KEEPOUT = 64 -- GUI kept clear of the right-side HUD column
local BOTTOM_MARGIN = 12 -- GUI kept clear at the screen bottom
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

	-- Placement. Boxes differ in width, so docking right of the WHOLE stack
	-- wastes the space beside its narrow tail: a panel whose top is at box
	-- j's top can only intersect the bands of boxes j..n (bands never
	-- overlap vertically), so it only has to clear THEIR right edges. Try
	-- j = 1..n in order -- top-aligned with the selected box when allowed
	-- (j <= sel), else at box j's top -- with the bottom-anchored slide-up
	-- floored at box j's top. Take the first candidate that shows every
	-- row; otherwise remember the one showing the most, and fall back to
	-- centered-below-the-stack only if it beats them all. This is what
	-- pushes the panel BELOW a wide mid-stack box (17-slot wand above two
	-- small ones) instead of folding it to a 2-row stub at the bottom.
	-- fit_y0/rows_at share one budget with the row clamp below, so a slid
	-- panel never folds rows it had room for.
	local fit_y0 = sh - BOTTOM_MARGIN - pad - 2 - (#rows + 1) * line_h
	local function rows_at(y)
		return math.floor((sh - BOTTOM_MARGIN - y - pad - 2 - line_h) / line_h)
	end
	local sel_top = anchor.boxes[anchor.sel].top
	local px, y0, best_n
	for j = 1, #anchor.boxes do
		local x = 0
		for k = j, #anchor.boxes do
			x = math.max(x, anchor.boxes[k].right)
		end
		x = math.floor(x) + DOCK_GAP
		if x + panel_w <= sw - RIGHT_KEEPOUT then
			local floor_y = anchor.boxes[j].top
			local y = math.max(sel_top, floor_y)
			if y > fit_y0 then y = math.max(floor_y, fit_y0) end
			y = math.floor(y)
			local n = rows_at(y)
			if n >= #rows then px, y0, best_n = x, y, nil; break end
			if best_n == nil or n > best_n then px, y0, best_n = x, y, n end
		end
	end
	if px == nil or (best_n ~= nil and rows_at(anchor.below_y) > best_n) then
		px = math.floor((sw - panel_w) / 2)
		y0 = math.floor(anchor.below_y)
	end

	-- clamp to the screen: keep the rows that fit, fold the rest
	local max_rows = math.floor((sh - BOTTOM_MARGIN - y0 - pad - 2 - line_h) / line_h)
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
	local show_panel = get("spell_bracket_visualizer.show_grouping") ~= false
	local show_slots = get("spell_bracket_visualizer.show_slot_brackets") ~= false
	if not show_panel and not show_slots then return end

	local sw, sh = GuiGetScreenDimensions(gui)

	-- one measure/read pass shared by the brackets and the panel's dock anchor
	local boxes, stack_bot = collect_wand_boxes(gui, sw)

	if show_slots then -- brackets on every wand box (independent of active wand)
		-- strongly negative z = "bring to front": lower z draws on top, and
		-- this must beat the engine's spell-frame layer, not just our own gui
		GuiZSet(gui, -10)
		draw_box_brackets(gui, sw, boxes)
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
			local geo = {} -- per-box GUI geometry for the dock candidates
			for i, b in ipairs(boxes) do
				geo[i] = { top = b.top * U * sw, right = b.right }
			end
			local anchor = {
				boxes   = geo,
				sel     = sel,
				below_y = stack_bot + DOCK_GAP,
			}
			draw_panel(gui, sim_rows(wd.sim, wd.cfg, wd.always), title, sw, sh, anchor)
		end
	end
end

return M
