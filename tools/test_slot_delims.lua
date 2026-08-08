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
-- GROUP IS ONE COLOR, and every delimiter is a real bracket. A group straddling
-- a wand wrap is drawn as four glyphs -- a [ ] pair around each half, all in
-- the group's own rainbow color, joined by the orange carriage return. It is
-- never drawn in WRAP_COLOR: orange belongs to the carriage return alone, and
-- painting the wrapped half orange is what made one group read as two.
-- The two glyphs the return attaches to are flagged `seam`; they are drawn
-- exactly like any other bracket.

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
-- cast delimiting, rainbow depth and wrap enclosure are all covered here rather
-- than re-implemented. Assumes a gap-free wand (card i sits in column i-1 on
-- row 0) unless `cols` says otherwise; the gap test at the end passes real
-- columns.
local function plan(tokens, spc, cols, rows)
	local sim = S.simulate(tokens, meta, { spells_per_cast = spc })
	cols = cols or {}
	rows = rows or {}
	for i = 1, #tokens do
		cols[i] = cols[i] or (i - 1)
		rows[i] = rows[i] or 0
	end
	local groups = T.collect_wand_delims(sim, cols, rows)
	return T.plan_delims(groups), groups, sim
end

-- "L0 R3^1 L1 R3" -- compact glyph rendering: side + column, "^N" = stack level
-- (omitted at 0, the innermost/on-the-card position).
local function show(glyphs)
	local out = {}
	for _, gl in ipairs(glyphs) do
		out[#out + 1] = ((gl.side == "left") and "L" or "R") .. gl.col
			.. ((gl.stack > 0) and ("^" .. gl.stack) or "")
	end
	return table.concat(out, " ")
end

local function same_color(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- WRAP_COLOR belongs to the wrap enclosure and nothing else: a GROUP or CAST
-- bracket drawn orange is the original bug (it read as an unrelated group).
local function orange_is_wrap_only(glyphs)
	for _, gl in ipairs(glyphs) do
		if same_color(gl.c, T.WRAP_COLOR) ~= (gl.wrap == true) then return false end
	end
	return true
end

-- ---- 1. the reported wand (screenshot 2026-08-07) --------------------------
--
-- LUMINOUS_DRILL / BURST_2 / HEAVY_SPREAD / SPARK_BOLT at 1 spell/cast.
-- cast 2 draws Double Spell (slot 2), gathers [Heavy spread] Spark bolt
-- (slots 3-4), then runs out of deck and WRAPS back to Luminous drill (slot 1).
-- The WRAP encloses the whole looping structure -- slot 1 (the card it pulled
-- back in) through slot 4 (where the cast ran out of deck) -- and the Double
-- Spell group sits inside it over its forward run, slots 2..4:
--
--     [ Luminous [Double, Heavy spread, Spark bolt] ]
--
-- Both casts fire a SINGLE spell expression, so neither is bracketed (nothing
-- fires simultaneously in a one-spell cast, and cast 2's span would have been
-- identical to the Double Spell group's -- one boundary drawn twice). The
-- rainbow still advances per cast, so the group lands at depth 2.
do
	local glyphs, groups, sim = plan(
		{ "LUMINOUS_DRILL", "BURST_2", "HEAVY_SPREAD", "SPARK_BOLT" }, 1)
	eq("report/two single-spell casts", #sim.casts[1].nodes .. "," .. #sim.casts[2].nodes, "1,1")
	eq("report/the wrap enclosure plus one group", #groups, 2)
	eq("report/glyphs", show(glyphs), "L0 R3^1 L1 R3")
	passck("report/the enclosure comes first, and is the wrap",
		groups[1].wrap == true and groups[1].ca == 0 and groups[1].cb == 3)
	passck("report/it is the only orange thing", orange_is_wrap_only(glyphs))
	passck("report/the closing bracket carries the tag",
		glyphs[2].label == "wraps to front" and glyphs[4].label == nil)
	-- the rainbow is ONE progression across both axes (user call 2026-08-07):
	-- every cast advances it by one, and so does every nesting level inside a
	-- group -- and a suppressed cast still consumes its slot, so the colors
	-- don't shift when a cast gains or loses a spell. cast 2 owns depth 1, so
	-- the Double Spell inside it is depth 2.
	passck("report/the group continues at depth 2", same_color(glyphs[3].c, T.nest_color(2)))
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
	local glyphs, groups, sim = plan({
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
	eq("wand12/wrap enclosure + four casts + one Pentagram group", #groups, 6)
	-- The wrap encloses columns 0..11, the WHOLE row -- including casts 1-3,
	-- which ran before the one that wrapped. So its [ on column 0 must stack
	-- OUTSIDE cast 1's, and its ] on column 11 outside cast 4's and the
	-- Pentagram's: it is collected before every other record for exactly that.
	passck("wand12/the enclosure spans the whole row",
		groups[1].wrap == true and groups[1].ca == 0 and groups[1].cb == 11)
	eq("wand12/glyphs", show(glyphs),
		"L0^1 R11^2 L0 R1 L2 R5 L6 R8 L9 R11^1 L11 R11")
	passck("wand12/the enclosure sits outside cast 1",
		glyphs[1].stack > glyphs[3].stack)
	passck("wand12/it is the only orange thing", orange_is_wrap_only(glyphs))
	for ci = 1, 4 do
		passck("wand12/cast " .. ci .. " takes rainbow slot " .. (ci - 1),
			same_color(groups[ci + 1].c, T.nest_color(ci - 1)))
	end
	passck("wand12/the Pentagram continues at depth 4",
		same_color(groups[6].c, T.nest_color(4)))
end

-- ---- 2. single cast, no wrap: plain nested pairs, no enclosure --------------
--
-- BURST_3 gathers a trigger that carries one payload spell: two nested groups,
-- both ending on the last card, so their closes stack (outer steps right).
-- The whole wand empties in ONE cast, so no cast bracket is drawn (a pair
-- around the entire slot row says nothing) and the groups keep depth 0 --
-- this wand renders exactly as it did before casts were delimited.
do
	local glyphs, groups, sim = plan(
		{ "BURST_3", "SPARK_BOLT", "BULLET_TIMER", "SPARK_BOLT" }, 4)
	eq("plain/one cast", #sim.casts, 1)
	passck("plain/does not wrap", not sim.wrapped)
	eq("plain/no cast bracket, no enclosure", #groups, 2)
	eq("plain/glyphs", show(glyphs), "L0 R3^1 L2 R3")
	passck("plain/nothing is orange", orange_is_wrap_only(glyphs))
	passck("plain/no labels", not (glyphs[2].label or glyphs[4].label))
	passck("plain/outer and inner differ in color",
		not same_color(glyphs[1].c, glyphs[3].c))
	passck("plain/outer stays at depth 0", same_color(glyphs[1].c, T.nest_color(0)))
	passck("plain/inner is depth-1", same_color(glyphs[3].c, T.nest_color(1)))
end

-- ---- 3. nested groups inside one enclosure ---------------------------------
--
-- SPARK / BURST_2 / BURST_2 / SPARK at 1/cast. Cast 2's outer Double Spell
-- gathers an inner Double Spell, which takes slot 4 and then wraps to slot 1.
-- ONE enclosure covers the loop (slots 1..4) and the two groups nest inside it
-- over their forward runs:  [ Spark [Double [Double, Spark]] ]
do
	local glyphs, groups = plan(
		{ "SPARK_BOLT", "BURST_2", "BURST_2", "SPARK_BOLT" }, 1)
	-- both casts fire a single spell, so neither is bracketed (case 1's rule)
	eq("nested/one enclosure + two groups, no cast brackets", #groups, 3)
	eq("nested/glyphs", show(glyphs), "L0 R3^2 L1 R3^1 L2 R3")
	passck("nested/the enclosure is outermost on the shared close",
		glyphs[2].wrap == true and glyphs[2].stack == 2)
	passck("nested/only the enclosure is orange", orange_is_wrap_only(glyphs))
	passck("nested/exactly one label", glyphs[2].label == "wraps to front"
		and not (glyphs[4].label or glyphs[6].label))
end

-- ---- 4. a group living wholly in the wrapped-in segment --------------------
--
-- BURST_2 / SPARK / SPARK / BURST_2 at 1/cast. Cast 2's Double Spell (slot 4)
-- wraps immediately and pulls in the wand's leading Double Spell, whose own
-- card was drawn AFTER the wrap -- so it has no forward run at all and falls
-- back to first..last, slots 1..3. Cast 2's own Double Spell has a forward run
-- of exactly its own card, slot 4. Column 0 therefore carries THREE opening
-- brackets (the enclosure, cast 1's group, and the wrapped-in group), which is
-- the overprint per-side stacking prevents; opens never stacked before the fix.
do
	local glyphs, groups, sim = plan(
		{ "BURST_2", "SPARK_BOLT", "SPARK_BOLT", "BURST_2" }, 1)
	local outer = sim.casts[2].nodes[1]
	local inner = outer.children[1]
	passck("fully/outer wrapped", outer.wfirst ~= nil)
	passck("fully/outer's forward run is its own card alone", outer.flast == 4)
	passck("fully/inner has no forward run at all", inner.flast == nil)
	eq("fully/enclosure + three groups", #groups, 4)
	eq("fully/glyphs", show(glyphs), "L0^2 R3^1 L0^1 R2^1 L3 R3 L0 R2")
	local st = {}
	for _, gl in ipairs(glyphs) do
		if gl.side == "left" and gl.col == 0 then st[#st + 1] = gl.stack end
	end
	eq("fully/all three column-0 opens got distinct stacks",
		table.concat(st, ","), "2,1,0")
	passck("fully/only the enclosure is orange", orange_is_wrap_only(glyphs))
end

-- ---- 5. empty slots: glyphs follow the real columns -------------------------
--
-- Same wand as case 1 but the cards sit in columns 0, 2, 3, 5 (gaps at 1 and
-- 4). Every glyph must move with its card -- the brackets hug slots, not deck
-- indices.
do
	local glyphs = plan({ "LUMINOUS_DRILL", "BURST_2", "HEAVY_SPREAD", "SPARK_BOLT" }, 1,
		{ 0, 2, 3, 5 })
	eq("gaps/glyphs", show(glyphs), "L0 R5^1 L2 R5")
end

-- ---- 6. a wrap with no group at all: just the enclosure ---------------------
--
-- SPARK_BOLT / DAMAGE at 1 spell/cast. Cast 2 draws the bare Damage modifier,
-- which force-draws its replacement, finds the deck empty and WRAPS onto Spark
-- bolt. Nothing on the wand has children, so no group is bracketed -- before
-- the wrap got its own enclosure this wand drew no slot-row apparatus at all.
do
	local glyphs, groups, sim = plan({ "SPARK_BOLT", "DAMAGE" }, 1)
	passck("bare/cast 2 wrapped", sim.casts[2].wfirst ~= nil)
	passck("bare/no node has children",
		#(sim.casts[2].nodes[1].children or {}) == 0)
	eq("bare/the enclosure is the only delimiter", #groups, 1)
	passck("bare/and it is the wrap", groups[1].wrap == true)
	eq("bare/glyphs", show(glyphs), "L0 R1")
	passck("bare/tagged", glyphs[2].label == "wraps to front")
end

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
