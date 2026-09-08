#!/usr/bin/env lua5.4
-- DIFFERENTIAL TEST: the mod's simulator vs Noita's own cast code.
--
--     lua5.4 tools/test_gun_differential.lua        (exit 1 on any divergence)
--
-- Runs every wand from tools/test_wand_structure.lua through BOTH
-- data/scripts/gun/gun.lua (the real thing, driven by tools/gun_harness.lua)
-- and files/wand_structure.lua, and fails if they disagree about what each cast
-- takes out of the deck.
--
-- WHY CONSUMPTION, NOT THE PLAY TRACE
--   A bracket in the mod means "the cards REMOVED from the deck while executing
--   the head card" (docs/ADVANCED_SCENARIOS_PLAN.md 0.1). Removed is not the
--   same as played. In "ADD_TRIGGER, LIGHT_BULLET, BOMB" the engine's scan
--   removes LIGHT_BULLET from the deck and then spawns its projectile from
--   related_projectiles -- it never calls the card's action body, so
--   LIGHT_BULLET never reaches play_action and never appears in the play trace.
--   Diffing traces would report a divergence on every trigger wand while the
--   brackets were in fact right. So the comparison unit is the per-cast SLOT
--   SET: harness `cast.drawn` (see the gun_harness.lua header for drawn vs
--   consumed) against simulator `cast.slots` (opts.trace = true), plus the
--   per-cast `wrapped` flag.
--
-- NOT A CI TEST
--   It needs .gun_ref/, which tools/extract_gun.py unpacks from the player's
--   own data.wak. Those are Noita's files: gitignored, never committed. With
--   .gun_ref/ absent this script prints one SKIP line and exits 0, so a CI run
--   that shells every tools/test_*.lua stays green. tools/test_wand_structure.lua
--   is the suite that always runs.
--
-- READING THE OUTPUT
--   PASS/FAIL per case; on FAIL both slot renderings are printed ("{1,2,3}W"
--   per cast, W = that cast wrapped). Runs that touched an engine call the
--   harness does not model are listed under UNSUPPORTED and are NOT compared --
--   a stub answering a question wrongly would produce a divergence that is the
--   harness's fault. A harness `error` result, by contrast, is a failure.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

local function exists(p)
	local fh = io.open(p, "r")
	if fh then fh:close() return true end
	return false
end

if not exists(MOD .. "/.gun_ref/data/scripts/gun/gun.lua") then
	print("SKIP tools/test_gun_differential.lua: .gun_ref/ missing "
		.. "(run `python3 tools/extract_gun.py` to unpack it from your data.wak)")
	os.exit(0)
end

local meta = dofile(MOD .. "/files/structure_meta.lua")
local S = dofile(MOD .. "/files/wand_structure.lua")
local H = dofile(MOD .. "/tools/gun_harness.lua")

-- ---- cases -----------------------------------------------------------------
--
-- Every wand tools/test_wand_structure.lua checks, in the same order, with the
-- same tokens and spells_per_cast. `casts` is how many casts to drive the
-- engine for -- at least as many as the unit test expects, since the harness
-- runs a fixed count while the simulator stops on its own (see below).
--
-- One substitution: the unit test uses "MAGIC_SHOT", which is not a Noita
-- action id at all (it is in neither gun_actions.lua nor structure_meta.lua,
-- so the simulator falls back to type OTHER and the engine cannot deck it).
-- SPITTER -- a real PROJECTILE, structurally the same plain leaf -- stands in
-- for it here. The unit test's expected strings are unaffected; only this file
-- needs an id the engine can actually load.
--
-- `uses` = { [slot] = uses_remaining } is passed to BOTH sides: the harness
-- decks the card with that charge count, the simulator gets it as opts.uses.
-- It is what checks the depleted-card model, which is entirely a claim about
-- the engine (draw_action discards a 0-use card unplayed and returns false;
-- draw_actions retries on the next card, under a `#deck > 0` guard that cannot
-- reload) -- so every one of those cases below has to be confirmed here rather
-- than reasoned about. There is no longer a pre-simulation filter to model:
-- the simulator is handed the FULL deck plus the charge counts.
local CASES = {
	{ name = "doc example, one cast",
	  tokens = { "DAMAGE", "BURST_2", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER", "SPITTER" },
	  spc = nil, casts = 3 },
	{ name = "spells/cast=2 splits casts",
	  tokens = { "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" },
	  spc = 2, casts = 3 },
	{ name = "root draws don't wrap",
	  tokens = { "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" }, spc = 2, casts = 3 },
	{ name = "trigger payload wraps to wand start",
	  tokens = { "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER" }, spc = 1, casts = 4 },
	{ name = "trailing modifier wraps",
	  tokens = { "LIGHT_BULLET", "DAMAGE" }, spc = 1, casts = 3 },
	{ name = "dangling modifier, no wrap possible",
	  tokens = { "DAMAGE" }, spc = 1, casts = 2 },
	{ name = "multicast wraps for missing child",
	  tokens = { "LIGHT_BULLET", "BURST_2", "SPITTER" }, spc = 1, casts = 3 },
	{ name = "RANDOM_MODIFIER chains (random pick, nearly all draw 1)",
	  tokens = { "RANDOM_MODIFIER", "LIGHT_BULLET" }, spc = 1, casts = 3 },
	{ name = "ALPHA does not chain (its draw is commented out in the game)",
	  tokens = { "ALPHA", "LIGHT_BULLET" }, spc = 1, casts = 2 },
	{ name = "GAMMA does not chain (its draw is commented out in the game)",
	  tokens = { "GAMMA", "LIGHT_BULLET" }, spc = 1, casts = 2 },
	{ name = "TAU does not chain (its draw is commented out in the game)",
	  tokens = { "TAU", "LIGHT_BULLET", "BOMB" }, spc = 1, casts = 3 },
	{ name = "BURST_X takes rest of deck",
	  tokens = { "BURST_X", "LIGHT_BULLET", "SPITTER", "SPITTER" }, spc = 1, casts = 2 },
	{ name = "DIVIDE chains to the next card",
	  tokens = { "DIVIDE_2", "LIGHT_BULLET" }, spc = 1, casts = 2 },
	{ name = "DIVIDE inside a multicast",
	  tokens = { "BURST_2", "DIVIDE_2", "LIGHT_BULLET", "SPITTER" }, spc = 1, casts = 2 },
	{ name = "trailing DIVIDE does not wrap",
	  tokens = { "LIGHT_BULLET", "DIVIDE_2" }, spc = 1, casts = 3 },
	{ name = "wrap restores slot order",
	  tokens = { "SPITTER", "LIGHT_BULLET", "BURST_2" }, spc = 1, casts = 4 },

	-- structural-span checks in the unit test reuse these wands
	{ name = "span: head excludes modifier prefix",
	  tokens = { "DAMAGE", "BURST_2", "LIGHT_BULLET", "SPITTER" }, spc = nil, casts = 2 },
	{ name = "span: wrapped span tracked",
	  tokens = { "BOUNCY_ORB", "SCATTER_2", "LIGHT", "BOUNCE" }, spc = 1, casts = 3 },

	-- ---- depleted cards: retried past, and the retry cannot wrap ----
	{ name = "depleted modifier is retried past, not filtered out",
	  tokens = { "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, spc = 1, casts = 3,
	  uses = { [2] = 0 } },
	{ name = "multicast retries past a depleted card and still gathers 2",
	  tokens = { "BURST_2", "LIGHT_BULLET", "SPITTER", "SPITTER" }, spc = 1, casts = 3,
	  uses = { [2] = 0 } },
	-- The two that pin down "the retry cannot wrap": in both, the LAST card of
	-- the deck is depleted, so the draw that reaches it is lost and no W appears
	-- on either side. Contrast "trailing modifier wraps" above, same shape but
	-- with the first attempt hitting a genuinely empty deck.
	{ name = "depleted last card: draw is lost, wand does NOT wrap",
	  tokens = { "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, spc = 1, casts = 4,
	  uses = { [3] = 0 } },
	{ name = "forced draw onto a depleted last card dangles, does NOT wrap",
	  tokens = { "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, spc = 1, casts = 4,
	  uses = { [3] = 0 } },
	{ name = "greek wand: depleted card still retried past",
	  tokens = { "TAU", "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, spc = 1, casts = 3,
	  uses = { [3] = 0 } },

	-- ---- the ADD_TRIGGER family: the forward scan ----
	{ name = "add trigger: target is the scanned projectile",
	  tokens = { "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
	{ name = "add trigger: scan swallows an intervening modifier",
	  tokens = { "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
	{ name = "add trigger: scan swallows several modifiers",
	  tokens = { "ADD_TRIGGER", "DAMAGE", "CRITICAL_HIT", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
	{ name = "add trigger: a second add trigger is consumed by the scan",
	  tokens = { "ADD_TRIGGER", "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
	{ name = "add trigger: payload count comes from the target's rp",
	  tokens = { "ADD_TRIGGER", "BALL_LIGHTNING", "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" },
	  spc = nil, casts = 2 },
	{ name = "add trigger: no card left to trigger, fires plainly",
	  tokens = { "ADD_TRIGGER", "LIGHT_BULLET" }, spc = nil, casts = 2 },
	{ name = "add trigger: scan off the end consumes nothing",
	  tokens = { "ADD_TRIGGER", "DAMAGE" }, spc = nil, casts = 2 },
	{ name = "add trigger: alone on the wand, does nothing",
	  tokens = { "ADD_TRIGGER" }, spc = nil, casts = 2 },
	{ name = "add timer: same scan, timer kind",
	  tokens = { "ADD_TIMER", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
	{ name = "add death trigger: same scan, death kind",
	  tokens = { "ADD_DEATH_TRIGGER", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
	{ name = "add trigger: modifier before it keeps its place",
	  tokens = { "DAMAGE", "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, spc = nil, casts = 2 },
}

-- Divergences already understood and traced to the ENGINE, not to a simulator
-- bug -- keyed by case name, value = why. Reported as KNOWN, still counted in
-- the summary line but not as failures.
-- (It used to also carry ALPHA and RANDOM_MODIFIER: tools/gen_structure_meta.py's
-- draw_actions regex read gun_actions.lua's commented-out
-- `--draw_actions( 1, true )` in the ALPHA/GAMMA/TAU bodies as live, and
-- RANDOM_MODIFIER's chaining -- inherited from whichever MODIFIER it
-- randomly picks -- wasn't modeled at all. Both are fixed at the generator:
-- comments are stripped before the draws regex runs, and RANDOM_MODIFIER now
-- carries draws=1, tier="approximate". This test caught both.)
local KNOWN = {
	["greek wand: depleted card still retried past"] =
		"ENGINE, not the simulator -- and not a regression from the Alpha/Gamma/"
		.. "Tau fix, just newly VISIBLE because of it. TAU's body reads deck[1] "
		.. "and deck[2] and calls BOTH of their `.action()` functions directly, "
		.. "bypassing draw_action's uses_remaining check entirely -- here deck[2] "
		.. "is DAMAGE, a MODIFIER whose own body ends in draw_actions(1, true). "
		.. "That forced draw fires from inside TAU's copy, popping the deck's "
		.. "front card (LIGHT_BULLET) for real, so the engine consumes {1,2} in "
		.. "cast 1 where the simulator -- correctly modeling TAU itself as a "
		.. "leaf now -- only consumes {1}. This is exactly the copy-live "
		.. "unpredictability docs/ADVANCED_SCENARIOS_PLAN.md Sec.2 calls out for "
		.. "ALPHA/GAMMA/TAU (D3 class 1, tier=\"approximate\"): what a Greek's "
		.. "copy indirectly consumes depends on what it happens to copy, which "
		.. "is state the simulator does not attempt to follow. Previously masked "
		.. "here by TAU's incorrectly inherited draws=1, which happened to "
		.. "consume the same second slot by coincidence (per the old version of "
		.. "this note). The case now decks DAMAGE with uses = 0, which makes the "
		.. "bypass literal rather than argued: the engine fires a card it has "
		.. "zero charges of, purely because a Greek copied it by position. "
		.. "Modeling it precisely is Track D work, not this task's.",
}

-- ---- comparison -------------------------------------------------------------

local function show_slots(cast)
	return "{" .. table.concat(cast.slots or cast.drawn or {}, ",") .. "}"
		.. (cast.wrapped and "W" or "")
end

local function show_sim(sim)
	local parts = {}
	for _, c in ipairs(sim.casts) do parts[#parts + 1] = show_slots(c) end
	return table.concat(parts, " | ")
end

local function same_list(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local failures, unsupported_n, known_n = 0, 0, 0
local notes = {}

for _, case in ipairs(CASES) do
	local run = H.run(case.tokens, case.spc or #case.tokens, case.casts or 3,
		{ uses = case.uses })
	local sim = S.simulate(case.tokens, meta,
		{ spells_per_cast = case.spc, trace = true, uses = case.uses })

	if run.unsupported then
		unsupported_n = unsupported_n + 1
		print(string.format("SKIP %s\n    unsupported engine calls: %s",
			case.name, table.concat(run.unsupported, ", ")))
	elseif run.error then
		failures = failures + 1
		print(string.format("FAIL %s\n    harness error: %s", case.name, run.error))
	else
		local bad = nil
		-- The simulator stops when the deck runs out or a cast wraps; the
		-- harness always runs `casts` casts (after a reload the wand simply
		-- starts over). So only the casts the simulator produced are compared,
		-- and a longer harness run is an informational line: it is the same
		-- wand cycling again, not a disagreement about this cycle.
		for i, sc in ipairs(sim.casts) do
			local hc = run.casts[i]
			if hc == nil then
				bad = "simulator produced cast " .. i .. ", harness ran only " .. #run.casts
				break
			end
			if not same_list(sc.slots, hc.drawn) then
				bad = "cast " .. i .. " slots differ"
				break
			end
			if (sc.wrapped and true or false) ~= (hc.wrapped and true or false) then
				bad = "cast " .. i .. " wrapped flag differs"
				break
			end
		end
		if bad == nil and #run.casts > #sim.casts then
			notes[#notes + 1] = string.format("%s (%d sim / %d gun)",
				case.name, #sim.casts, #run.casts)
		end
		if bad and KNOWN[case.name] then
			known_n = known_n + 1
			print(string.format("KNOWN %s (%s)\n    %s\n    sim %s\n    gun %s",
				case.name, bad, KNOWN[case.name], show_sim(sim), H.show_consumed(run)))
		elseif bad then
			failures = failures + 1
			print(string.format("FAIL %s (%s)\n    sim %s\n    gun %s\n    gun(consumed) %s\n    gun(trace) %s",
				case.name, bad, show_sim(sim), H.show_consumed(run),
				H.show_consumed(run, "consumed"), H.show(run)))
		else
			print("PASS " .. case.name)
		end
	end
end

-- Informational only: the harness runs a fixed number of casts, so once the
-- simulator has stopped (deck empty, or a wrap ended the recharge cycle) the
-- engine simply reloads and casts the same wand again. That is agreement about
-- a second cycle, not a disagreement about the first.
if #notes > 0 then
	print(string.format("\n%d case(s) where the harness cast past the "
		.. "simulator's last cast (the wand recharged and cycled again)", #notes))
end
print(string.format("\n%d divergence(s), %d unsupported, %d known",
	failures, unsupported_n, known_n))
os.exit(failures > 0 and 1 or 0)
