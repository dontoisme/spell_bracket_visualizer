#!/usr/bin/env lua5.4
-- Runs the REAL files/grouping_overlay.lua delimiter planner (collect_delims +
-- plan_delims) against the REAL simulator and the REAL structure_meta, so the
-- slot-bracket NESTING is covered without the game:
--
--     lua5.4 tools/test_slot_delims.lua
--
-- Both functions are pure -- columns, rows, colors and stack indices, no Gui
-- and no pixels -- which is exactly why the planning was split out of
-- draw_delims. Everything below the planner (x/y arithmetic, hook drawing) is
-- still eyeball-verified from a screenshot; see docs/GROUPING_DESIGN.md.
--
-- The invariant these tests exist to protect (regression 2026-08-07): ONE
-- GROUP IS ONE BRACKET PAIR IN ONE COLOR. A group straddling a wand wrap is
-- drawn as four glyphs -- real [ , cut end, cut end, real ] -- not as two
-- self-closed pairs, and never in WRAP_COLOR (orange belongs to the carriage
-- return alone).

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

-- grouping_overlay.lua resolves its deps through the game's dofile_once.
function dofile_once(path)
	local rel = path:match("^mods/spell_bracket_visualizer/(.*)$")
	assert(rel, "unexpected dofile_once path: " .. tostring(path))
	return dofile(MOD .. "/" .. rel)
end

local meta = dofile(MOD .. "/files/structure_meta.lua")
local S = dofile(MOD .. "/files/wand_structure.lua")
local overlay = dofile(MOD .. "/files/grouping_overlay.lua")
local T = assert(overlay._test, "grouping_overlay.lua did not return its _test exports")
assert(T.collect_delims and T.plan_delims, "_test is missing the delimiter planner")

-- ---- tiny check harness (same conventions as test_wand_structure.lua) -------

local failures = 0
local function passck(name, ok, detail)
	if ok then
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
	end
end
local function eq(name, got, want)
	passck(name, got == want, tostring(got) .. " ~= " .. tostring(want))
end

-- ---- plan a wand -----------------------------------------------------------

-- Simulate `tokens` at `spc` spells/cast and plan its slot glyphs, through the
-- REAL collect_wand_delims -- the same entry point draw_box_brackets uses, so
-- cast delimiting, rainbow depth and connector ownership are all covered here
-- rather than re-implemented. Assumes a gap-free wand (card i sits in column
-- i-1 on row 0) unless `cols` says otherwise; the gap test at the end passes
-- real columns.
local function plan(tokens, spc, cols, rows)
	local sim = S.simulate(tokens, meta, { spells_per_cast = spc })
	cols = cols or {}
	rows = rows or {}
	for i = 1, #tokens do
		cols[i] = cols[i] or (i - 1)
		rows[i] = rows[i] or 0
	end
	local groups = T.collect_wand_delims(sim, cols, rows)
	local glyphs, links = T.plan_delims(groups)
	return glyphs, links, groups, sim
end

-- "L2 R3c L0c R0" -- compact glyph rendering: side + column, "c" = cut end,
-- "^N" = stack level (omitted at 0, the innermost/on-the-card position).
local function show(glyphs)
	local out = {}
	for _, gl in ipairs(glyphs) do
		out[#out + 1] = ((gl.side == "left") and "L" or "R") .. gl.col
			.. (gl.cut and "c" or "")
			.. ((gl.stack > 0) and ("^" .. gl.stack) or "")
	end
	return table.concat(out, " ")
end

local function same_color(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- No glyph may ever be drawn in WRAP_COLOR: orange is the carriage return's.
local function no_orange(glyphs)
	for _, gl in ipairs(glyphs) do
		if same_color(gl.c, T.WRAP_COLOR) then return false end
	end
	return true
end

-- ---- 1. the reported wand (screenshot 2026-08-07) --------------------------
--
-- LUMINOUS_DRILL / BURST_2 / HEAVY_SPREAD / SPARK_BOLT at 1 spell/cast.
-- cast 2 draws Double Spell (slot 2), gathers [Heavy spread] Spark bolt
-- (slots 3-4), then runs out of deck and WRAPS back to Luminous drill (slot 1).
-- The Double Spell group straddles: [ on slot 2, cut end on slot 4, cut end on
-- slot 1, ] on slot 1. Before the fix this was a gold [2..4] pair PLUS a
-- self-closed orange [1] pair, which read as two sibling groups.
-- Both casts fire a SINGLE spell expression, so neither is bracketed (nothing
-- fires simultaneously in a one-spell cast, and cast 2's span would have been
-- identical to the Double Spell group's -- one boundary drawn twice). The
-- rainbow still advances per cast, so the group lands at depth 2.
do
	local glyphs, links, groups, sim = plan(
		{ "LUMINOUS_DRILL", "BURST_2", "HEAVY_SPREAD", "SPARK_BOLT" }, 1)
	eq("report/two single-spell casts", #sim.casts[1].nodes .. "," .. #sim.casts[2].nodes, "1,1")
	eq("report/neither cast is bracketed", #groups, 1)
	eq("report/glyphs", show(glyphs), "L1 R3c L0c R0")
	eq("report/one carriage return", #links, 1)
	eq("report/return leaves the forward cut end", links[1] and links[1].from, 2)
	eq("report/return arrives at the wrapped cut end", links[1] and links[1].to, 3)
	passck("report/one group one color",
		same_color(glyphs[1].c, glyphs[2].c) and same_color(glyphs[2].c, glyphs[3].c)
			and same_color(glyphs[3].c, glyphs[4].c))
	passck("report/brackets are rainbow, not orange", no_orange(glyphs))
	-- the rainbow is ONE progression across both axes (user call 2026-08-07):
	-- every cast advances it by one, and so does every nesting level inside a
	-- group -- and a suppressed cast still consumes its slot, so the colors
	-- don't shift when a cast gains or loses a spell. cast 2 owns depth 1, so
	-- the Double Spell inside it is depth 2.
	passck("report/the group continues at depth 2", same_color(glyphs[1].c, T.nest_color(2)))
end

-- ---- 1b. cast spans and the rainbow across many casts ----------------------
--
-- The 12-slot wand from the second screenshot, 2 spells/cast: four casts, the
-- last one wrapping out of a Pentagram (5-way multicast). Casts 1-3 hold only
-- leaves -- a spell plus its modifier prefix -- so before casts were delimited
-- this whole wand drew exactly ONE bracket pair. Cast spans must cover the
-- modifier prefixes, not just the spell that fires. Every cast here fires TWO
-- spells, so unlike case 1 every cast is bracketed.
do
	local glyphs, links, groups, sim = plan({
		"TNTBOX", "TNTBOX", "HORIZONTAL_ARC", "GUNPOWDER_TRAIL", "TNTBOX", "TNTBOX",
		"SPIRALING_SHOT", "TNTBOX", "TNTBOX", "RECOIL", "TNTBOX", "PENTAGRAM_SHAPE" }, 2)
	eq("wand12/four casts", #sim.casts, 4)
	local function span(ci)
		local c = sim.casts[ci]
		return c.first .. ".." .. c.last
			.. (c.wfirst and (" w" .. c.wfirst .. ".." .. c.wlast) or "")
	end
	eq("wand12/cast 1 span", span(1), "1..2")
	eq("wand12/cast 2 span", span(2), "3..6")  -- [Aiming Arc, Gunpowder trail] Box, Box
	eq("wand12/cast 3 span", span(3), "7..9")  -- [Spiral Arc] Box, Box
	eq("wand12/cast 4 span", span(4), "10..12 w1..8") -- wraps into the wand's start
	eq("wand12/four casts + one Pentagram group", #groups, 5)
	-- cast 1's [ on column 0 stacks OUTSIDE cast 4's and the Pentagram's wrapped
	-- cut ends, which land on the same column; the wrapped halves close for real
	-- on column 7 (slot 8), the last card the wrap pulled in.
	eq("wand12/glyphs", show(glyphs),
		"L0^2 R1 L2 R5 L6 R8 L9 R11c^1 L0c^1 R7^1 L11 R11c L0c R7")
	eq("wand12/one carriage return", #links, 1)
	for ci = 1, 4 do
		passck("wand12/cast " .. ci .. " takes rainbow slot " .. (ci - 1),
			same_color(groups[ci <= 3 and ci or 4].c, T.nest_color(ci - 1)))
	end
	passck("wand12/the Pentagram continues at depth 4",
		same_color(groups[5].c, T.nest_color(4)))
end

-- ---- 2. single cast, no wrap: plain nested pairs, no cut ends ---------------
--
-- BURST_3 gathers a trigger that carries one payload spell: two nested groups,
-- both ending on the last card, so their closes stack (outer steps right).
-- The whole wand empties in ONE cast, so no cast bracket is drawn (a pair
-- around the entire slot row says nothing) and the groups keep depth 0 --
-- this wand renders exactly as it did before casts were delimited.
do
	local glyphs, links, groups, sim = plan(
		{ "BURST_3", "SPARK_BOLT", "BULLET_TIMER", "SPARK_BOLT" }, 4)
	eq("plain/one cast", #sim.casts, 1)
	passck("plain/does not wrap", not sim.wrapped)
	eq("plain/no cast bracket", #groups, 2)
	eq("plain/no carriage returns", #links, 0)
	eq("plain/glyphs", show(glyphs), "L0 R3^1 L2 R3")
	passck("plain/no cut ends", not (glyphs[2].cut or glyphs[4].cut))
	passck("plain/outer and inner differ in color",
		not same_color(glyphs[1].c, glyphs[3].c))
	passck("plain/outer stays at depth 0", same_color(glyphs[1].c, T.nest_color(0)))
	passck("plain/inner is depth-1", same_color(glyphs[3].c, T.nest_color(1)))
end

-- ---- 3. nested straddle: ancestors split too, one carriage return -----------
--
-- SPARK / BURST_2 / BURST_2 / SPARK at 1/cast. Cast 2's outer Double Spell
-- gathers an inner Double Spell, which takes slot 4 and then wraps to slot 1.
-- The inner group straddles -- and so does the outer, which contains it. Both
-- are drawn split (an ancestor that closed on slot 4 would be lying about
-- where its group ends), stacking around the inner one; only the INNERMOST
-- draws the orange return.
do
	local glyphs, links, groups = plan(
		{ "SPARK_BOLT", "BURST_2", "BURST_2", "SPARK_BOLT" }, 1)
	-- both casts fire a single spell, so neither is bracketed (case 1's rule)
	eq("nested/two groups, no cast brackets", #groups, 2)
	eq("nested/glyphs", show(glyphs), "L1 R3c^1 L0c^1 R0^1 L2 R3c L0c R0")
	eq("nested/exactly one carriage return", #links, 1)
	passck("nested/the INNERMOST straddler owns it",
		links[1] and links[1].from == 6 and links[1].to == 7,
		links[1] and (links[1].from .. "->" .. links[1].to) or "none")
	passck("nested/the OUTER group straddles too, and is drawn split",
		glyphs[2].cut and glyphs[3].cut)
	passck("nested/brackets are rainbow, not orange", no_orange(glyphs))
end

-- ---- 4. fully-wrapped group: an ordinary pair, not a split one --------------
--
-- BURST_2 / SPARK / SPARK / BURST_2 at 1/cast. Cast 2's Double Spell (slot 4)
-- wraps immediately and pulls in the wand's leading Double Spell, whose own
-- card was drawn AFTER the wrap (hwrap). That inner group sits wholly in the
-- wrapped segment, so it straddles nothing and closes normally on slot 3.
-- Its opening [ lands on column 0 -- the same left-side position as the outer
-- group's wrapped cut end AND as cast 1's own Double Spell (all casts are
-- delimited on the one slot row). That is a THREE-way overprint on column 0,
-- exactly what the per-side stacking prevents; opens never stacked at all
-- before the fix, so all three drew on the same pixel column.
do
	local glyphs, links, groups, sim = plan(
		{ "BURST_2", "SPARK_BOLT", "SPARK_BOLT", "BURST_2" }, 1)
	local outer = sim.casts[2].nodes[1]
	local inner = outer.children[1]
	passck("fully/outer straddles", outer.wfirst ~= nil and not outer.hwrap)
	passck("fully/inner is wholly wrapped", inner.hwrap == true)
	eq("fully/three groups, no cast brackets", #groups, 3)
	eq("fully/glyphs", show(glyphs), "L0^2 R2^2 L3 R3c L0c^1 R2^1 L0 R2")
	eq("fully/one carriage return", #links, 1)
	passck("fully/the outer group owns it (its child straddles nothing)",
		links[1] and links[1].from == 4 and links[1].to == 5,
		links[1] and (links[1].from .. "->" .. links[1].to) or "none")
	passck("fully/inner has no cut ends", not (glyphs[7].cut or glyphs[8].cut))
	local st = {}
	for _, gl in ipairs(glyphs) do
		if gl.side == "left" and gl.col == 0 then st[#st + 1] = gl.stack end
	end
	eq("fully/all three column-0 opens got distinct stacks",
		table.concat(st, ","), "2,1,0")
end

-- ---- 5. empty slots: glyphs follow the real columns -------------------------
--
-- Same wand as case 1 but the cards sit in columns 0, 2, 3, 5 (gaps at 1 and
-- 4). Every glyph must move with its card -- the brackets hug slots, not deck
-- indices.
do
	local glyphs = plan({ "LUMINOUS_DRILL", "BURST_2", "HEAVY_SPREAD", "SPARK_BOLT" }, 1,
		{ 0, 2, 3, 5 })
	eq("gaps/glyphs", show(glyphs), "L2 R5c L0c R0")
end

-- ---- 6. a wrap with no group at all: the cast owns the carriage return ------
--
-- SPARK_BOLT / DAMAGE at 1 spell/cast. Cast 2 draws the bare Damage modifier,
-- which force-draws its replacement, finds the deck empty and WRAPS onto Spark
-- bolt. The result is one leaf whose own card came from after the wrap, so
-- nothing on the wand has children and NO group is bracketed -- before casts
-- were delimited this wand drew no wrap apparatus whatsoever. The cast bracket
-- is now the only thing that straddles, so it takes the carriage return -- and
-- that is exactly the exception to the single-spell rule in case 1: cast 2
-- fires one spell, but suppressing its bracket would throw the wrap away, so
-- it survives while cast 1's (one spell, no wrap) is dropped.
do
	local glyphs, links, groups, sim = plan({ "SPARK_BOLT", "DAMAGE" }, 1)
	passck("bare/cast 2 straddles", sim.casts[2].wfirst ~= nil)
	passck("bare/no node has children",
		#(sim.casts[2].nodes[1].children or {}) == 0)
	eq("bare/only the wrapping cast survives", #groups, 1)
	eq("bare/glyphs", show(glyphs), "L1 R1c L0c R0")
	eq("bare/the cast draws the carriage return", #links, 1)
	passck("bare/from the cast's own cut ends",
		links[1] and links[1].from == 2 and links[1].to == 3,
		links[1] and (links[1].from .. "->" .. links[1].to) or "none")
end

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
