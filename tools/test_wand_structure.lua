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

local function check(name, tokens, spc, expect)
	local got = show(S.simulate(tokens, meta, { spells_per_cast = spc }))
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

check("RANDOM_MODIFIER is terminal",
	{ "RANDOM_MODIFIER", "LIGHT_BULLET" }, 1,
	"{RANDOM_MODIFIER} | {LIGHT_BULLET}")

check("ALPHA chains",
	{ "ALPHA", "LIGHT_BULLET" }, 1,
	"{[ALPHA]LIGHT_BULLET}")

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

-- Depleted-card rule (read_deck drops uses_remaining == 0 before simulating).
-- The engine test is literally `== 0`: only 0 is depleted.
passck("card_fires: 0 depleted", S.card_fires(0) == false)
passck("card_fires: -1 unlimited keeps", S.card_fires(-1) == true)
passck("card_fires: -2 unlimited-unlimited keeps", S.card_fires(-2) == true)
passck("card_fires: 3 charges keeps", S.card_fires(3) == true)
passck("card_fires: nil (unreadable) keeps", S.card_fires(nil) == true)

-- End-to-end: a depleted MODIFIER drops out, so it no longer chains onto the
-- next projectile. [LIGHT, DAMAGE@0, LIGHT] @1/cast -> filter -> [LIGHT, LIGHT].
local function keep_fires(cards) -- cards = { {id=, uses=}, ... }, mirrors read_deck
	local out = {}
	for _, c in ipairs(cards) do
		if S.card_fires(c.uses) then out[#out + 1] = c.id end
	end
	return out
end
local filtered = keep_fires({
	{ id = "LIGHT_BULLET", uses = -1 },
	{ id = "DAMAGE", uses = 0 }, -- depleted modifier: must NOT chain
	{ id = "LIGHT_BULLET", uses = 5 },
})
check("depleted modifier filtered before sim",
	filtered, 1,
	"{LIGHT_BULLET} | {LIGHT_BULLET}")

-- Greek override: a wand containing a Greek spell KEEPS depleted cards (Greeks
-- re-cast by position). Mirrors read_deck: filter only when no Greek present.
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

local function read_deck_keep(cards) -- {id,uses}; mirrors read_deck's Greek gate
	local ids = {}
	for _, c in ipairs(cards) do ids[#ids + 1] = c.id end
	local greek = S.has_greek(ids)
	local out = {}
	for _, c in ipairs(cards) do
		if greek or S.card_fires(c.uses) then out[#out + 1] = c.id end
	end
	return out
end
-- Same wand WITH a Greek (Tau) in slot 1: the depleted DAMAGE is now kept and
-- chains onto the trailing LIGHT (Tau itself is type OTHER, draws 1 -> chains).
local greek_kept = read_deck_keep({
	{ id = "TAU", uses = -1 },
	{ id = "LIGHT_BULLET", uses = -1 },
	{ id = "DAMAGE", uses = 0 }, -- depleted but KEPT because the wand has a Greek
	{ id = "LIGHT_BULLET", uses = 5 },
})
check("greek wand keeps depleted card",
	greek_kept, 1,
	"{[TAU]LIGHT_BULLET} | {[DAMAGE]LIGHT_BULLET}")

print(string.format("\n%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
