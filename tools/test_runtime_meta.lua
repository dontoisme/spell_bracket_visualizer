#!/usr/bin/env lua5.4
-- Unit test for files/runtime_meta.lua -- the runtime (modded-spell) metadata
-- fallback layer described in docs/ADVANCED_SCENARIOS_PLAN.md 3 A1.
--
--     lua5.4 tools/test_runtime_meta.lua
--
-- Four things are covered, in order of how much of the game they need:
--   1. the pure walker + merge, driven by an INJECTED actions table (no game,
--      no .gun_ref) -- a modded MODIFIER, a modded DRAW_MANY, a vanilla id that
--      must still come from structure_meta, and an id in neither;
--   2. end-to-end through the REAL simulator: a modded modifier must become a
--      prefix of the next spell instead of a cast-ending leaf (Night's bug);
--   3. a real-file smoke test that loads .gun_ref/'s own gun_enums.lua +
--      gun_actions.lua exactly the way M.load() does in-game -- this is what
--      proves the file needs no file-scope globals beyond its own dofile_once
--      deps (skipped with a message when .gun_ref/ is absent);
--   4. the failure path: a dofile_once that throws must leave the mod running
--      on plain structure_meta.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."
local REF = MOD .. "/.gun_ref/data/scripts"

local structure_meta = dofile(MOD .. "/files/structure_meta.lua")
assert(type(structure_meta) == "table", "structure_meta.lua did not return a table")
local S = dofile(MOD .. "/files/wand_structure.lua")

-- Each test gets its OWN module instance: M.load() is idempotent by design, so
-- state must not leak between the injected, real-file and failing cases.
local function fresh()
	local m = dofile(MOD .. "/files/runtime_meta.lua")
	assert(type(m) == "table" and m.load, "runtime_meta.lua did not return a module")
	return m
end

-- ---- tiny check harness (same conventions as test_slot_delims.lua) ---------

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

-- ---- compact tree printer (copied from test_wand_structure.lua) ------------

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

-- ---- 1. injected actions table --------------------------------------------
-- Shaped exactly like a mod's ModLuaFileAppend entries: numeric `type` drawn
-- from the ACTION_TYPE_* globals, which we define here the way gun_enums.lua
-- does so the value->name mapping is exercised for real.

ACTION_TYPE_PROJECTILE        = 0
ACTION_TYPE_STATIC_PROJECTILE = 1
ACTION_TYPE_MODIFIER          = 2
ACTION_TYPE_DRAW_MANY         = 3
ACTION_TYPE_MATERIAL          = 4
ACTION_TYPE_OTHER             = 5
ACTION_TYPE_UTILITY           = 6
ACTION_TYPE_PASSIVE           = 7

local FAKE = {
	{ id = "MOD_X",     name = "$action_mod_x",     type = ACTION_TYPE_MODIFIER, mana = 7 },
	{ id = "MOD_MANY",  name = "$action_mod_many",  type = ACTION_TYPE_DRAW_MANY, mana = 20 },
	{ id = "MOD_SHOT",  name = "$action_mod_shot",  type = ACTION_TYPE_PROJECTILE,
	  related_projectiles = { "data/x.xml", 4 } },
	{ id = "MOD_UTIL",  name = "$action_mod_util",  type = ACTION_TYPE_UTILITY },
	-- a vanilla id, present in structure_meta: the runtime record must LOSE
	{ id = "LIGHT_BULLET", name = "$action_light_bullet", type = ACTION_TYPE_PROJECTILE,
	  related_projectiles = { "data/lb.xml" } },
}

local RT = fresh()
eq("injected load status", RT.load(FAKE), "ok")
eq("injected count", RT.count, 5)

local merged = RT.merged(structure_meta)

local mx = merged["MOD_X"]
passck("modded MODIFIER present", mx ~= nil)
eq("  MOD_X type", mx and mx.type, "MODIFIER")
eq("  MOD_X draws", mx and mx.draws, 1)
eq("  MOD_X tier", mx and mx.tier, "approximate")
eq("  MOD_X name", mx and mx.name, "$action_mod_x")
eq("  MOD_X mana", mx and mx.mana, 7)

local mm = merged["MOD_MANY"]
eq("modded DRAW_MANY type", mm and mm.type, "DRAW_MANY")
eq("  MOD_MANY tier", mm and mm.tier, "unknown")
passck("  MOD_MANY has NO draw count (never guess a multicast width)",
	mm ~= nil and mm.draws == nil and mm.group == nil)

local ms = merged["MOD_SHOT"]
eq("modded PROJECTILE tier", ms and ms.tier, "approximate")
eq("  MOD_SHOT rp from related_projectiles[2]", ms and ms.rp, 4)

eq("modded UTILITY tier", merged["MOD_UTIL"] and merged["MOD_UTIL"].tier, "unknown")
-- no `mana` field on MOD_UTIL: gun.lua's ACTION_MANA_DRAIN_DEFAULT is 10, not 0
eq("  MOD_UTIL mana defaults to 10", merged["MOD_UTIL"] and merged["MOD_UTIL"].mana, 10)

-- structure_meta wins for a vanilla id, even though the runtime read has it
local lb = merged["LIGHT_BULLET"]
passck("vanilla id comes from structure_meta", lb == structure_meta["LIGHT_BULLET"])
passck("  and it carries no runtime tier", lb ~= nil and lb.tier == nil)
eq("source(LIGHT_BULLET)", RT.source("LIGHT_BULLET"), "meta")
eq("source(MOD_X)", RT.source("MOD_X"), "runtime")
eq("source(NOT_A_SPELL)", RT.source("NOT_A_SPELL"), nil)

-- neither layer: nil, so wand_structure's meta_for() still answers {type="OTHER"}
eq("unknown id merges to nil", merged["NOT_A_SPELL"], nil)

-- the merge is a metatable, not a 422-entry copy
passck("merged table is not a copy", next(merged) == nil)
-- cached second read returns the SAME record (no per-frame garbage)
passck("fallback records are cached", merged["MOD_X"] == mx)

eq("status_line (ok)", RT.status_line(), "runtime actions: 5 loaded (ok)")

-- ---- 2. end to end through the real simulator ------------------------------
-- Without the fallback, MOD_X is {type="OTHER"} -- a leaf that ends the cast,
-- so this wand would read as TWO casts. That is Night's report.

eq("modded modifier prefixes the next spell",
	show(S.simulate({ "MOD_X", "LIGHT_BULLET" }, merged, { spells_per_cast = 1 })),
	"{[MOD_X]LIGHT_BULLET}")

eq("without the fallback it splits into two casts (the bug)",
	show(S.simulate({ "MOD_X", "LIGHT_BULLET" }, structure_meta, { spells_per_cast = 1 })),
	"{MOD_X} | {LIGHT_BULLET}")

-- ---- 3. real-file smoke test ----------------------------------------------
-- Loads .gun_ref/'s gun_enums.lua + gun_actions.lua through a dofile_once shim
-- that maps data/scripts/... onto .gun_ref/, i.e. the exact sequence M.load()
-- runs in the game. gun_actions.lua pulls its own two deps
-- (procedural/gun_action_utils.lua and lib/utilities.lua) via the same shim; if
-- it ever needs another file-scope global, this test is where that shows up.

local function have(p)
	local fh = io.open(p, "r")
	if fh then fh:close() return true end
	return false
end

if not have(REF .. "/gun/gun_actions.lua") then
	print("SKIP real-file smoke test -- .gun_ref/ missing (run tools/extract_gun.py)")
else
	local seen = {}
	local prev_dofile_once, prev_actions = dofile_once, actions
	dofile_once = function(path)
		if seen[path] then return end
		seen[path] = true
		local f = REF .. "/" .. (path:gsub("^data/scripts/", ""))
		if not have(f) then error("missing dep: " .. path, 0) end
		return dofile(f)
	end
	actions = nil

	local R = fresh()
	eq("real load status", R.load(), "ok")
	passck("real action count >= 400", R.count >= 400, tostring(R.count))

	local rm = R.merged({})  -- empty structure_meta: read the runtime layer alone
	eq("ADD_TRIGGER runtime type", rm["ADD_TRIGGER"] and rm["ADD_TRIGGER"].type, "OTHER")
	eq("ADD_TRIGGER tier", rm["ADD_TRIGGER"] and rm["ADD_TRIGGER"].tier, "unknown")
	eq("BALL_LIGHTNING rp", rm["BALL_LIGHTNING"] and rm["BALL_LIGHTNING"].rp, 3)
	eq("ALPHA mana", rm["ALPHA"] and rm["ALPHA"].mana, 40)
	eq("LIGHT_BULLET rp defaults to 1", rm["LIGHT_BULLET"] and rm["LIGHT_BULLET"].rp, 1)
	dofile_once, actions = prev_dofile_once, prev_actions
end

-- ---- 4. failure path -------------------------------------------------------
-- The read must never take the panel down with it.

do
	local prev_dofile_once = dofile_once
	dofile_once = function() error("data.wak on fire", 0) end

	local F = fresh()
	local st = F.load()
	passck("failed load reports failure", st:sub(1, 7) == "failed:", st)
	passck("  status_line names it",
		F.status_line():sub(1, 24) == "runtime actions: failed:", F.status_line())
	eq("  runtime table empty", F.count, 0)

	local fm = F.merged(structure_meta)
	passck("merged still serves structure_meta",
		fm["LIGHT_BULLET"] == structure_meta["LIGHT_BULLET"])
	eq("  and nothing else", fm["MOD_X"], nil)
	eq("  simulator degrades to today's behavior",
		show(S.simulate({ "DAMAGE", "LIGHT_BULLET" }, fm, { spells_per_cast = 1 })),
		show(S.simulate({ "DAMAGE", "LIGHT_BULLET" }, structure_meta, { spells_per_cast = 1 })))

	dofile_once = prev_dofile_once
end

-- ---- 5. grouping_overlay wiring -------------------------------------------
-- The overlay must ask for the merged table, and must survive runtime_meta
-- failing (its ensure_ helper is wrapped in pcall).

do
	local prev_dofile_once = dofile_once
	dofile_once = function(path)
		local rel = path:match("^mods/spell_bracket_visualizer/(.*)$")
		assert(rel, "unexpected dofile_once path: " .. tostring(path))
		return dofile(MOD .. "/" .. rel)
	end
	local overlay = dofile(MOD .. "/files/grouping_overlay.lua")
	local T = assert(overlay._test, "grouping_overlay.lua did not return _test")
	passck("overlay exports the runtime hook",
		type(T.ensure_runtime_meta) == "function" and type(T.effective_meta) == "function")
	passck("effective meta starts as plain structure_meta",
		T.effective_meta()["LIGHT_BULLET"] ~= nil)
	-- in this VM data/scripts/... is not resolvable, so the load FAILS: the
	-- point is that ensure_runtime_meta() does not raise.
	local ok = pcall(T.ensure_runtime_meta)
	passck("ensure_runtime_meta never raises", ok)
	passck("effective meta still usable after a failed runtime read",
		T.effective_meta()["LIGHT_BULLET"] ~= nil)
	dofile_once = prev_dofile_once
end

-- ---------------------------------------------------------------------------

if failures > 0 then
	print(string.format("\n%d FAILURE(S)", failures))
	os.exit(1)
end
print("\nall runtime_meta tests passed")
