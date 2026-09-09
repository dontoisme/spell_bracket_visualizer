#!/usr/bin/env lua5.4
-- Ground-truth unit test of the shipped wand_structure.lua simulator,
-- running against the real generated files/structure_meta.lua.
-- This harness executes the exact Lua that ships in the mod.
--
--     lua5.4 tools/test_wand_structure.lua
--
-- The independent cross-check is tools/test_gun_differential.lua, which runs
-- Noita's own gun.lua from .gun_ref/ (extracted by tools/extract_gun.py).
-- It verifies the simulator against the engine on every test wand.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

local meta = dofile(MOD .. "/files/structure_meta.lua")
assert(type(meta) == "table", "structure_meta.lua did not return a table")
local n = 0
for _ in pairs(meta) do n = n + 1 end
assert(n > 400, "structure_meta.lua parse failed (" .. n .. " entries)")

local S = dofile(MOD .. "/files/wand_structure.lua")
assert(type(S) == "table" and S.simulate, "wand_structure.lua did not return a module")

-- ---- compact tree printer ------------

local function show_node(node)
	local mods = ""
	if #node.modifiers > 0 then
		mods = "[" .. table.concat(node.modifiers, ",") .. "]"
	end
	local tag = ""
	if node.kind == "multicast" then
		tag = "x" .. (node.group == -1 and "all" or tostring(node.group))
	elseif node.kind == "trigger" then
		tag = "trig" .. tostring(node.payload)
	elseif node.kind == "reset" then
		-- RESET's bracket is the rest of the wand. The cleared slots are listed,
		-- not counted, because WHICH slots they are is the whole claim -- and on
		-- a wand where RESET clears nothing (it is the last card) the empty
		-- "clears[]" says so out loud instead of reading as a plain leaf.
		tag = "clears[" .. table.concat(node.cleared, ",") .. "]"
	end
	if node.dangling then tag = "dangling" end
	if node.wrap then tag = tag .. "~WRAP" end
	local head = mods .. node.id .. (tag ~= "" and (":" .. tag) or "")
	if node.children and #node.children > 0 then
		local kids = {}
		for _, c in ipairs(node.children) do kids[#kids + 1] = show_node(c) end
		return "(" .. head .. " " .. table.concat(kids, " ") .. ")"
	end
	return head
end

local function show(sim)
	local parts = {}
	for _, c in ipairs(sim.casts) do
		local body = {}
		for _, node in ipairs(c.nodes) do body[#body + 1] = show_node(node) end
		parts[#parts + 1] = "{" .. table.concat(body, " ") .. "}" .. (c.wrapped and "W" or "")
	end
	return table.concat(parts, " | ")
end

-- ---- tests ------------

local failures = 0

-- `uses` (optional) = { [slot] = uses_remaining }, handed straight to the
-- simulator: 0 = depleted, which the engine retries past (see below).
local function check(name, tokens, spc, expect, uses)
	local got = show(S.simulate(tokens, meta, { spells_per_cast = spc, uses = uses }))
	local ok = got == expect
	if not ok then failures = failures + 1 end
	print(string.format("%s %s\n    expect %s\n    got    %s",
		ok and "PASS" or "FAIL", name, expect, got))
end

check("doc example, one cast",
	{ "DAMAGE", "BURST_2", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER", "SPITTER" },
	nil,
	"{([DAMAGE]BURST_2:x2 LIGHT_BULLET (LIGHT_BULLET_TRIGGER:trig1 SPITTER))}")

check("spells/cast=2 splits casts",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" }, 2,
	"{LIGHT_BULLET LIGHT_BULLET} | {LIGHT_BULLET LIGHT_BULLET}")

check("root draws don't wrap",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" }, 2,
	"{LIGHT_BULLET LIGHT_BULLET} | {LIGHT_BULLET}")

check("trigger payload wraps to wand start",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER" }, 1,
	"{LIGHT_BULLET} | {LIGHT_BULLET} | " ..
	"{(LIGHT_BULLET_TRIGGER:trig1~WRAP LIGHT_BULLET:~WRAP)}W")

check("trailing modifier wraps",
	{ "LIGHT_BULLET", "DAMAGE" }, 1,
	"{LIGHT_BULLET} | {[DAMAGE]LIGHT_BULLET:~WRAP}W")

check("dangling modifier, no wrap possible",
	{ "DAMAGE" }, 1,
	"{[DAMAGE]DAMAGE:dangling}")

check("multicast wraps for missing child",
	{ "LIGHT_BULLET", "BURST_2", "SPITTER" }, 1,
	"{LIGHT_BULLET} | {(BURST_2:x2~WRAP SPITTER LIGHT_BULLET:~WRAP)}W")

-- RANDOM_MODIFIER's body never calls draw_actions() itself (it picks a
-- random MODIFIER and invokes its action directly), but nearly every
-- MODIFIER body ends in draw_actions(1, true), so in play it chains onto the
-- next card almost always -- confirmed by tools/test_gun_differential.lua
-- running this against the real gun.lua with three different random picks,
-- all of which chained. structure_meta.lua models this as draws=1,
-- tier="approximate" (which modifier gets picked, and so the exact chained
-- spell, is not statically knowable, but "chains" is right far more often
-- than "terminates").
check("RANDOM_MODIFIER chains (random pick, nearly all draw 1)",
	{ "RANDOM_MODIFIER", "LIGHT_BULLET" }, 1,
	"{[RANDOM_MODIFIER]LIGHT_BULLET}")

-- Alpha's body ends with a COMMENTED-OUT `--draw_actions( 1, true )`: it
-- re-casts a card it already has (discarded[1], else hand[1], else deck[1])
-- and force-draws NOTHING, so it consumes only its own slot and does not
-- chain onto the next card. (GAMMA and TAU carry the same dead line.)
check("ALPHA does not chain (its draw is commented out in the game)",
	{ "ALPHA", "LIGHT_BULLET" }, 1,
	"{ALPHA} | {LIGHT_BULLET}")

check("BURST_X takes rest of deck",
	{ "BURST_X", "LIGHT_BULLET", "SPITTER", "SPITTER" }, 1,
	"{(BURST_X:xall LIGHT_BULLET SPITTER SPITTER)}")

-- DIVIDE_* invoke deck[1] directly (no draw_actions call) -> they chain like
-- a modifier prefix, firing WITH the next card in the same cast.
check("DIVIDE chains to the next card",
	{ "DIVIDE_2", "LIGHT_BULLET" }, 1,
	"{[DIVIDE_2]LIGHT_BULLET}")

-- ...so a multicast gathering a divide expression spans divide + its target.
check("DIVIDE inside a multicast",
	{ "BURST_2", "DIVIDE_2", "LIGHT_BULLET", "SPITTER" }, 1,
	"{(BURST_2:x2 [DIVIDE_2]LIGHT_BULLET SPITTER)}")

-- ...but unlike a modifier, a divide on an empty deck does NOTHING: it reads
-- the deck directly instead of force-drawing, so it never pulls the discard
-- back in. Trailing DAMAGE wraps (see above); trailing DIVIDE must not.
check("trailing DIVIDE does not wrap",
	{ "LIGHT_BULLET", "DIVIDE_2" }, 1,
	"{LIGHT_BULLET} | {[DIVIDE_2]DIVIDE_2:dangling}")

check("wrap restores slot order",
	{ "SPITTER", "LIGHT_BULLET", "BURST_2" }, 1,
	"{SPITTER} | {LIGHT_BULLET} | " ..
	"{(BURST_2:x2~WRAP SPITTER:~WRAP LIGHT_BULLET)}W")

-- span / head / wrapped-span structural checks
local function passck(name, ok, detail)
	if not ok then failures = failures + 1 end
	print(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail or ""))
end

local sim = S.simulate({ "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER" }, meta, { spells_per_cast = 1 })
local node = sim.casts[3].nodes[1]
passck("wrap span reaches slot 1", node.first == 1 and node.last == 3,
	string.format(" (first=%s last=%s)", node.first, node.last))

sim = S.simulate({ "DAMAGE", "BURST_2", "LIGHT_BULLET", "SPITTER" }, meta, {})
node = sim.casts[1].nodes[1]
passck("head excludes modifier prefix", node.first == 1 and node.head == 2 and node.last == 4,
	string.format(" (first=%s head=%s last=%s)", node.first, node.head, node.last))

sim = S.simulate({ "BOUNCY_ORB", "SCATTER_2", "LIGHT", "BOUNCE" }, meta, { spells_per_cast = 1 })
node = sim.casts[2].nodes[1]
passck("wrapped span tracked",
	node.head == 2 and node.last == 4 and node.wfirst == 1 and node.wlast == 1 and node.wrap,
	string.format(" (head=%s last=%s wfirst=%s wlast=%s)", node.head, node.last, node.wfirst, node.wlast))

-- Depleted-card rule. The engine test is literally `== 0`: only 0 is depleted.
passck("card_fires: 0 depleted", S.card_fires(0) == false)
passck("card_fires: -1 unlimited keeps", S.card_fires(-1) == true)
passck("card_fires: -2 unlimited-unlimited keeps", S.card_fires(-2) == true)
passck("card_fires: 3 charges keeps", S.card_fires(3) == true)
passck("card_fires: nil (unreadable) keeps", S.card_fires(nil) == true)

-- End-to-end: a depleted MODIFIER is RETRIED PAST, not filtered out of the deck.
-- draw_action pops it, discards it unplayed and returns false; draw_actions then
-- re-draws on the next card. So it does not chain onto the trailing projectile --
-- but it IS gone from the deck, and cast 2 therefore consumes slots 2 AND 3.
-- (Confirmed against the real gun.lua: tools/test_gun_differential.lua.)
check("depleted modifier is retried past, not filtered out",
	{ "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{LIGHT_BULLET} | {LIGHT_BULLET}", { [2] = 0 })

-- ...and the retry does not count toward the draw: a multicast asked for 2 still
-- gathers two FIRING cards, stepping over the depleted one on the way.
check("multicast retries past a depleted card and still gathers 2",
	{ "BURST_2", "LIGHT_BULLET", "SPITTER", "SPITTER" }, 1,
	"{(BURST_2:x2 SPITTER SPITTER)}", { [2] = 0 })

-- THE RETRY CANNOT WRAP (gun.lua:305 -- `while #deck > 0`, which never reaches
-- draw_action's instant_reload_if_empty path). Cast 3's root draw pops the
-- depleted DAMAGE, retries, finds the deck empty, and the draw is LOST: no wrap,
-- no recharge-ending W. The cast still happened and still emptied slot 3, so it
-- is a real cast with nodes = {} and cast.spent = {3}.
check("depleted last card: draw is lost, wand does NOT wrap",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, 1,
	"{LIGHT_BULLET} | {LIGHT_BULLET} | {}", { [3] = 0 })

-- Same rule one level down, and the contrast that makes it visible: in
-- "trailing modifier wraps" above, DAMAGE's forced draw finds an EMPTY deck on
-- its FIRST attempt and wraps. Here the deck is not empty -- it holds a depleted
-- card -- so the first attempt spends it and the RETRY hits the empty deck.
-- Same wand shape, opposite outcome: the modifier dangles and nothing wraps.
check("forced draw onto a depleted last card dangles, does NOT wrap",
	{ "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{LIGHT_BULLET} | {[DAMAGE]DAMAGE:dangling}", { [3] = 0 })

-- The consumption bookkeeping behind the three cases above: a depleted card is
-- in the cast's span and its slot list (it WAS taken out of the deck), reported
-- separately as cast.spent, and in no node.
sim = S.simulate({ "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, meta,
	{ spells_per_cast = 1, trace = true, uses = { [3] = 0 } })
local c3 = sim.casts[3]
passck("depleted-only cast exists with no nodes",
	#sim.casts == 3 and #c3.nodes == 0 and not c3.wrapped and not sim.wrapped,
	string.format(" (casts=%d nodes=%d wrapped=%s)", #sim.casts, #c3.nodes,
		tostring(c3.wrapped)))
passck("depleted card is consumed: in slots, in the span, in cast.spent",
	c3.slots[1] == 3 and #c3.slots == 1 and c3.first == 3 and c3.last == 3
		and c3.spent ~= nil and c3.spent[1] == 3 and #c3.spent == 1,
	string.format(" (slots=%d first=%s spent=%s)", #c3.slots, tostring(c3.first),
		tostring(c3.spent and c3.spent[1])))
passck("a cast with no depleted card reports no spent list",
	sim.casts[1].spent == nil)

-- The Greek list no longer gates a depleted-card filter (there is no filter) --
-- it survives because the confidence tiering needs it: a Greek copies a card by
-- POSITION and invokes its body directly, bypassing the uses_remaining check
-- entirely, which is exactly what the simulator cannot follow.
passck("has_greek: TAU present", S.has_greek({ "LIGHT_BULLET", "TAU", "DAMAGE" }) == true)
passck("has_greek: none", S.has_greek({ "LIGHT_BULLET", "DAMAGE" }) == false)
passck("has_greek: DIVIDE is not Greek", S.has_greek({ "DIVIDE_10", "LIGHT_BULLET" }) == false)

-- ---- ADD_TRIGGER family: the forward scan (see wand_structure.lua) ---------
-- All nine wands below were run through Noita's real gun.lua with
-- tools/gun_harness.lua and agree with it on which cards each expression
-- CONSUMES, which is what a bracket means. The engine trace and this tree
-- differ in what they SHOW: the engine spawns the trigger from the target's
-- related_projectiles and never calls its action body, so the target never
-- appears as "played" -- but it is removed from the deck, so it is the head
-- here.

check("add trigger: target is the scanned projectile, next card is the payload",
	{ "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")

-- The scan steps over modifiers and CONSUMES them (the engine also runs each
-- one against the trigger projectile), so they join the prefix, not a later cast.
check("add trigger: scan swallows an intervening modifier",
	{ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER,DAMAGE]LIGHT_BULLET:trig1 BOMB)}")

check("add trigger: scan swallows several modifiers",
	{ "ADD_TRIGGER", "DAMAGE", "CRITICAL_HIT", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER,DAMAGE,CRITICAL_HIT]LIGHT_BULLET:trig1 BOMB)}")

-- A stepped-over Add Trigger is counted and consumed but never executed
-- (the body excludes its own family from the inline modifier call).
check("add trigger: a second add trigger is consumed by the scan",
	{ "ADD_TRIGGER", "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER,ADD_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")

-- payload size is the TARGET's related_projectiles count, not a literal 1:
-- Ball Lightning declares 3, so the trigger draws three 1-card payloads.
-- Found in-game: the payload draw pops a 0-charge Bomb, the retry finds the
-- deck empty, the payload is lost and the wand does NOT wrap. The trigger still
-- fires (with nothing under it); the spent slot is consumed, not bracketed.
check("add trigger: payload onto a depleted card is lost, no wrap",
	{ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, 1,
	"{[ADD_TRIGGER,DAMAGE]LIGHT_BULLET:trig1}", { [4] = 0 })

check("add trigger: payload count comes from the target's rp",
	{ "ADD_TRIGGER", "BALL_LIGHTNING", "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" }, nil,
	"{([ADD_TRIGGER]BALL_LIGHTNING:trig3 LIGHT_BULLET LIGHT_BULLET LIGHT_BULLET)}")

-- With nothing projectile-ish left in the deck the body's `valid` check fails:
-- it casts the consumed card plainly and spawns NO trigger (and draws no payload).
check("add trigger: no card left to trigger, so it fires plainly",
	{ "ADD_TRIGGER", "LIGHT_BULLET" }, nil,
	"{[ADD_TRIGGER]LIGHT_BULLET}")

-- Scan runs off the end of the deck -> the body consumes nothing at all, and
-- the modifier it stepped over is still in the deck to be drawn normally.
-- (The engine applies that modifier's body twice -- once in the scan, once when
-- drawn -- but that is shot state, not deck consumption, so no bracket says it.)
check("add trigger: scan off the end consumes nothing",
	{ "ADD_TRIGGER", "DAMAGE" }, nil,
	"{ADD_TRIGGER [DAMAGE]DAMAGE:dangling}")

check("add trigger: alone on the wand, does nothing",
	{ "ADD_TRIGGER" }, nil,
	"{ADD_TRIGGER}")

-- Add Timer / Add Death Trigger share the body; only the trigger kind differs.
check("add timer: same scan, timer kind",
	{ "ADD_TIMER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TIMER]LIGHT_BULLET:trig1 BOMB)}")

check("add death trigger: same scan, death kind",
	{ "ADD_DEATH_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_DEATH_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")

-- A modifier BEFORE the add trigger prefixes it as usual, and stays in front
-- of the scanned cards in the prefix list.
check("add trigger: modifier before it keeps its place in the prefix",
	{ "DAMAGE", "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([DAMAGE,ADD_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")

-- Same rule on a wand holding a Greek. There is no longer a "keep depleted cards
-- when a Greek is present" override -- the card is kept in the deck for EVERY
-- wand now, and retried past when it is drawn -- so the depleted DAMAGE does not
-- chain onto the trailing LIGHT_BULLET here either. (Tau itself does not chain:
-- its body's draw_actions(1, true) is commented out in the game, so it is a leaf.
-- What Tau's copy does to the deck is the one KNOWN engine divergence in
-- tools/test_gun_differential.lua, and it is unaffected by this.)
check("greek wand: depleted card still retried past",
	{ "TAU", "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{TAU} | {LIGHT_BULLET} | {LIGHT_BULLET}", { [3] = 0 })

-- ---- RESET: the bracket is the rest of the wand (T1.10) --------------------
-- RESET calls no draw_actions at all. Its body moves every card in `hand` and
-- every card in `deck` to `discarded`, empties both, and then -- unless
-- force_stop_draws is already set -- sets it and calls move_discarded_to_deck()
-- + order_deck(), handing the deck straight back FULL in slot order. So:
--   * the cards it took out of the deck are cleared, not spent and not cast:
--     no draw_action ran for them, so they cost no mana and fire nothing. They
--     are listed as node.cleared and printed here as "clears[...]".
--   * the restore is a WRAP by every meaning the mod attaches to the word (the
--     deck is back at the wand's start and later draws in this cast are
--     wrapped-in), and tools/gun_harness.lua counts it as one, so the cast
--     carries W and the recharge cycle ends after it.
-- Every wand below was run through the real gun.lua first; the differential
-- cases in tools/test_gun_differential.lua are the same wands.

check("reset clears the rest of the wand and ends the cycle",
	{ "LIGHT_BULLET", "RESET", "SPITTER", "BOMB" }, 1,
	"{LIGHT_BULLET} | {RESET:clears[3,4]~WRAP}W")

check("reset clears a single trailing card",
	{ "RESET", "SPITTER" }, 1,
	"{RESET:clears[2]~WRAP}W")

-- Alone on the wand there is nothing left to clear -- but RESET still PLAYS
-- (it is drawn and its body runs), so it is a real node with an empty bracket,
-- not a no-op and not a leaf.
check("reset with an empty deck clears nothing and is still a node",
	{ "RESET" }, 1,
	"{RESET:clears[]~WRAP}W")

-- A modifier in front of RESET prefixes it exactly like any other head.
check("reset takes a modifier prefix",
	{ "DAMAGE", "RESET", "SPITTER" }, 1,
	"{[DAMAGE]RESET:clears[3]~WRAP}W")

-- THE INTERESTING ONE, and the case that corrects
-- docs/ADVANCED_SCENARIOS_PLAN.md Sec.4 D6. D6 says the cast ends at RESET
-- because the deck is empty. It does not: the tail of RESET's body hands the
-- whole discard pile back as a full deck, so the multicast's SECOND child is
-- drawn from the wand's start and finds BURST_2 again. That second BURST_2
-- draws RESET again -- and this time force_stop_draws is already set, so the
-- restore is skipped, the deck really does stay empty, and its own second
-- child cannot be drawn (nor can it wrap: force_stop_draws also disables
-- draw_action's reload path). Confirmed against gun.lua, which plays exactly
-- "BURST_2 >RESET ~>BURST_2 ~>>RESET" and reports slots {1,2,3,4}.
check("reset inside a multicast: the restore feeds the next child from slot 1",
	{ "BURST_2", "RESET", "SPITTER", "BOMB" }, 1,
	"{(BURST_2:x2~WRAP RESET:clears[3,4]~WRAP (BURST_2:x2 RESET:clears[3,4]))}W")

-- The bookkeeping behind those trees: cleared slots are inside the node's span
-- (the bracket must reach them) and listed on the node, but they are not
-- children and they are not `spent` -- RESET moves a card whether or not it had
-- charges left, which is a different thing from a depleted card being retried
-- past. And `cast.slots` NETS OUT: the cast drew RESET and cleared slots 3-4,
-- then handed all of them back to the deck, so on balance it removed nothing --
-- which is exactly what the engine's own deck diff reports.
sim = S.simulate({ "LIGHT_BULLET", "RESET", "SPITTER", "BOMB" }, meta,
	{ spells_per_cast = 1, trace = true })
local rnode = sim.casts[2].nodes[1]
passck("reset node: kind, head and cleared list",
	rnode.kind == "reset" and rnode.head == 2
		and #rnode.cleared == 2 and rnode.cleared[1] == 3 and rnode.cleared[2] == 4
		and rnode.children == nil,
	string.format(" (kind=%s head=%s cleared=%d)", tostring(rnode.kind),
		tostring(rnode.head), #rnode.cleared))
passck("reset node: the span covers the cleared cards",
	rnode.first == 2 and rnode.last == 4,
	string.format(" (first=%s last=%s)", tostring(rnode.first), tostring(rnode.last)))
passck("reset cast: nets out to no slots, and reports no spent cards",
	#sim.casts[2].slots == 0 and sim.casts[2].spent == nil and sim.casts[2].wrapped,
	string.format(" (slots=%d spent=%s)", #sim.casts[2].slots,
		tostring(sim.casts[2].spent)))
-- A DEPLETED card that RESET clears is cleared, not spent: RESET moves every
-- card in the deck regardless of charges, and never looks at uses_remaining.
sim = S.simulate({ "RESET", "SPITTER", "BOMB" }, meta,
	{ spells_per_cast = 1, trace = true, uses = { [2] = 0 } })
passck("a depleted card RESET clears is cleared, not spent",
	sim.casts[1].spent == nil and #sim.casts[1].nodes[1].cleared == 2)

-- ---- tiers (T1.3) ------------

local function eq(name, got, expect)
	local ok = got == expect
	if not ok then failures = failures + 1 end
	print(string.format("%s %s\n    expect %s\n    got    %s",
		ok and "PASS" or "FAIL", name, tostring(expect), tostring(got)))
end

local function check_tier(name, ids, m, expect_tier, expect_offenders)
	local t, off = S.wand_tier(ids, m or meta)
	local got = t .. " {" .. table.concat(off, ",") .. "}"
	local expect = expect_tier .. " {" .. table.concat(expect_offenders, ",") .. "}"
	eq(name, got, expect)
end

eq("tier: nil record is unknown", S.tier(nil), "unknown")
eq("tier: no tier field is exact", S.tier(meta["LIGHT_BULLET"]), "exact")
eq("tier: ALPHA is approximate", S.tier(meta["ALPHA"]), "approximate")
eq("tier: ZETA is unknown", S.tier(meta["ZETA"]), "unknown")
-- Defensive: a record that says it is dynamic but forgot its tier is still at
-- least approximate (the generator sets both; a runtime record might not).
eq("tier: dynamic without tier is approximate",
	S.tier({ type = "OTHER", dynamic = "random" }), "approximate")

check_tier("wand tier: all-exact wand",
	{ "DAMAGE", "LIGHT_BULLET", "BOMB" }, nil, "exact", {})
check_tier("wand tier: empty wand", {}, nil, "exact", {})
check_tier("wand tier: ALPHA makes it approximate",
	{ "LIGHT_BULLET", "ALPHA", "BOMB" }, nil, "approximate", { "ALPHA" })
check_tier("wand tier: ZETA wins, offenders in appearance order",
	{ "ZETA", "LIGHT_BULLET", "ALPHA" }, nil, "unknown", { "ZETA", "ALPHA" })
check_tier("wand tier: id absent from meta is unknown",
	{ "LIGHT_BULLET", "MODDED_MYSTERY" }, nil, "unknown", { "MODDED_MYSTERY" })
check_tier("wand tier: duplicate offenders collapse",
	{ "ALPHA", "ALPHA", "LIGHT_BULLET", "ALPHA" }, nil,
	"approximate", { "ALPHA" })
-- A synthetic (runtime-shaped) record with dynamic but no tier still counts.
local synth = setmetatable({ ODDBALL = { type = "OTHER", dynamic = "random" } },
	{ __index = meta })
check_tier("wand tier: synthetic dynamic record via __index fallback",
	{ "LIGHT_BULLET", "ODDBALL" }, synth, "approximate", { "ODDBALL" })

-- ---- per-cast mana (T1.8) ------------

-- Costs are read out of the generated table, never hardcoded here.
local function cost(id) return meta[id].mana end

local function check_mana(name, tokens, spc, expect, uses)
	local sim = S.simulate(tokens, meta, { spells_per_cast = spc, uses = uses })
	local got = {}
	for _, c in ipairs(sim.casts) do got[#got + 1] = "mana=" .. tostring(c.mana) end
	local want = {}
	for _, v in ipairs(expect) do want[#want + 1] = "mana=" .. tostring(v) end
	eq(name, table.concat(got, " | "), table.concat(want, " | "))
end

check_mana("mana: single card is its own cost",
	{ "LIGHT_BULLET" }, nil, { cost("LIGHT_BULLET") })

-- The scan (ADD_TRIGGER + the target it lands on, LIGHT_BULLET) is removed by
-- direct table.remove into `hand`, never draw_action, so neither card is
-- charged. BOMB is the trigger's payload, drawn for real via parse_seq/draw(),
-- so it is charged like any other card.
check_mana("mana: add trigger's scanned cards are free, its payload is not",
	{ "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	{ cost("ADD_TRIGGER") + cost("BOMB") })

-- Same shape with a modifier stepped over in the scan (DAMAGE): it too is
-- swept up by the scan's direct removal, never drawn, so it is free as well --
-- only the payload (BOMB) costs anything.
check_mana("mana: a modifier stepped over by the scan is also free",
	{ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, nil,
	{ cost("ADD_TRIGGER") + cost("BOMB") })

-- An id with no record at all costs ACTION_MANA_DRAIN_DEFAULT (10).
check_mana("mana: unknown id contributes the default 10",
	{ "LIGHT_BULLET", "MODDED_MYSTERY" }, nil,
	{ cost("LIGHT_BULLET") + 10 })

-- Add Mana (MANA_REDUCE) has a NEGATIVE cost: it credits the pool, so the
-- cast total goes down and can even go negative.
assert(cost("MANA_REDUCE") < 0, "MANA_REDUCE should have negative mana")
check_mana("mana: Add Mana subtracts",
	{ "MANA_REDUCE", "LIGHT_BULLET" }, nil,
	{ cost("MANA_REDUCE") + cost("LIGHT_BULLET") })

check_mana("mana: per-cast, not per-wand",
	{ "LIGHT_BULLET", "BOMB" }, 1,
	{ cost("LIGHT_BULLET"), cost("BOMB") })

-- Only cards the cast PLAYED are billed. draw_action reaches
-- `mana = mana - action_mana_required` only after both of its early returns, so
-- a DEPLETED card is discarded unplayed and costs nothing -- cast 3 below pops
-- slot 3, fires nothing, and is free.
check_mana("mana: a depleted card is popped but not charged",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, 1,
	{ cost("LIGHT_BULLET"), cost("LIGHT_BULLET"), 0 }, { [3] = 0 })

-- Same rule, other card class: a card RESET cleared never went through
-- draw_action at all, so the cast costs RESET (plus any prefix) and nothing for
-- the two cards it emptied out of the deck.
check_mana("mana: cards RESET clears are free",
	{ "LIGHT_BULLET", "RESET", "SPITTER", "BOMB" }, 1,
	{ cost("LIGHT_BULLET"), cost("RESET") })

check_mana("mana: a prefix on RESET is still charged",
	{ "DAMAGE", "RESET", "SPITTER" }, 1,
	{ cost("DAMAGE") + cost("RESET") })

print(string.format("\n%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
