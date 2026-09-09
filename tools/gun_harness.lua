-- Run Noita's OWN cast code (data/scripts/gun/gun.lua) outside the game, so the
-- mod's re-implementation can be checked against it.
--
-- Not a test by itself -- tools/test_gun_differential.lua drives this and diffs
-- the result against files/wand_structure.lua. Requires .gun_ref/, which
-- tools/extract_gun.py writes from the player's own data.wak (never committed).
--
-- HOW IT WORKS
--   gun.lua is plain Lua over global state: `deck`, `discarded`, `hand`, and a
--   handful of engine functions it calls out to. Nothing in the draw path needs
--   the engine to do anything -- add_projectile and friends are pure side
--   effects on the world. So we stub the engine, load the real file, and drive
--   _start_shot / _draw_actions_for_shot exactly as the game does.
--
-- THE STUB HAZARD (why this file counts what it doesn't know)
--   A stub that answers a question wrongly is worse than one that refuses to:
--   an action body branching on a bogus ComponentGetValue2 produces a divergence
--   that is the HARNESS's fault, and it will look exactly like a mod bug. So
--   every engine call not explicitly modelled below is recorded by name, and a
--   run that touched one is reported `unsupported` rather than compared. The
--   differential test lists those separately -- they are known-uncovered, not
--   passes.
--
-- WHAT IT RECORDS
--   The draw TRACE: per cast, the cards played in order with the nesting depth
--   they were drawn at, plus whether the deck wrapped. That is exactly the
--   abstraction the mod renders, and it means add_projectile never has to do
--   anything -- which is what collapses gun_actions.lua's 260 projectile call
--   sites into one no-op.
--
--   ...and per cast, the SLOTS the cast took out of the deck. That, not the
--   play trace, is what a bracket means (docs/ADVANCED_SCENARIOS_PLAN.md 0.1):
--   an Add Trigger's target is removed from the deck and never played -- the
--   engine spawns its projectile from related_projectiles and never calls its
--   action body -- so a play-trace diff would report a phantom divergence on
--   every trigger wand.
--
--   DRAWN vs CONSUMED (why there are two fields, and which one to diff)
--     cast.consumed = (deck at cast start) minus (deck at end of the draw
--       phase). Simple, but WRONG across a wrap: the wrap pulls the discard
--       back into the deck, so cards drawn after it were never in the start
--       set, and cards returned by the wrap but not re-drawn are in the start
--       set yet still sit in the deck. On "LIGHT_BULLET, LIGHT_BULLET,
--       LIGHT_BULLET_TRIGGER" @1/cast the wrapping third cast consumes slots
--       1 and 3, but before-minus-after says only {3}.
--     cast.drawn = (deck at cast start, UNION deck contents immediately after
--       each wrap) minus (deck at end of the draw phase). That is every slot
--       the cast removed from the deck by ANY route -- an ordinary draw, a
--       depleted/no-mana skip (draw_action discards without playing), or an
--       action body's own table.remove(deck, ...) (the Add Trigger scan, the
--       DIVIDE_* bodies). It is measured from the deck itself, so it needs no
--       hook on the removal sites.
--   >>> The differential test diffs `drawn`; `consumed` is kept as a
--       cross-check and is expected to differ from it on wrapping casts only.
--
--   The end of the DRAW PHASE, not the end of the cast, is where the "after"
--   snapshot is taken: _draw_actions_for_shot ends with _handle_reload, which
--   on the last cast of a cycle moves the whole discard pile back into the
--   deck. Snapshotting after that would show a full deck and report nothing
--   consumed. The root draw_shot wrapper below takes it at exactly the right
--   moment. For the same reason a wrap is only counted while cards are being
--   drawn (depth > 0): _handle_reload's move_discarded_to_deck is a RELOAD,
--   not a wrap.

local M = {}

-- Resolve paths from THIS file's own location, not arg[0]: the harness is
-- loaded as a module by the differential test, so the running script may live
-- anywhere.
local here = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."
local MOD = here .. "/.."
local REF = MOD .. "/.gun_ref/data/scripts"

local function exists(p)
	local fh = io.open(p, "r")
	if fh then fh:close() return true end
	return false
end

if not exists(REF .. "/gun/gun.lua") then
	error("\n.gun_ref/ is missing -- the harness needs the game's own cast code.\n"
		.. "Run:  python3 tools/extract_gun.py\n"
		.. "(It reads your data.wak; the files are gitignored, never committed.)\n")
end

-- ---- engine stubs ----------------------------------------------------------

-- Every engine call the draw path makes that we deliberately model as a no-op.
-- These are side effects on the world (spawning projectiles, reflection
-- plumbing, logging) -- nothing in the draw order depends on their return.
local NOOP = {
	"Reflection_RegisterProjectile", "BeginProjectile", "EndProjectile",
	"BeginTriggerTimer", "BeginTriggerHitWorld", "BeginTriggerDeath",
	"EndTrigger", "BaabInstruction", "SetProjectileConfigs", "SetRandomSeed",
	"OnActionPlayed", "OnNotEnoughManaForAction", "ActionUsesRemainingChanged",
	"ActionUsed", "StartReload", "LogAction", "print_error", "GamePrint",
	"ComponentSetValue2", "EntityInflictDamage", "EntityLoad", "EntityKill",
	"GameAddFlagRun", "GameRemoveFlagRun", "AddFlagPersistent",
	"RemoveFlagPersistent", "GameScreenshake", "LoadPixelScene",
	-- reflection sinks in the *_generated.lua config files: PassToGame hands
	-- the finished config to C++. Nothing reads back.
	"RegisterGunAction", "RegisterGunShotEffects",
}

-- A root card is played inside draw_shot -> draw_actions, i.e. two frames of
-- our depth counter. Subtract them so a root card reads 0 and each forced draw
-- a card makes itself reads 1, 2, ... -- the nesting the mod draws.
local ROOT_DEPTH = 2

-- Engine calls we answer, because the draw path actually reads what they say.
-- Deliberately conservative: each returns the value that keeps an action body
-- on its ordinary path, and anything NOT listed here lands in `unknown` below.
local frame = 0
local function make_env()
	for _, name in ipairs(NOOP) do _G[name] = function() end end

	GameGetFrameNum = function() frame = frame + 1; return frame end
	-- Deterministic LCG: the engine's Random is seeded per shot, and a
	-- differential run has to be reproducible. Only order_deck (shuffle wands)
	-- and the random-draw spells consume it -- both are reported unsupported.
	local seed = 1
	Random = function(a, b)
		seed = (seed * 1103515245 + 12345) % 2147483648
		if a == nil then return seed / 2147483648 end
		if b == nil then a, b = 1, a end
		return a + (seed % (b - a + 1))
	end
	GlobalsGetValue = function(_, default) return default or "0" end
	HasFlagPersistent = function() return false end
end

-- Any engine call NOT modelled above. Recorded by name and no-opped; a run that
-- touches one is reported unsupported instead of compared. Only CamelCase names
-- are treated this way (the engine API convention) -- a lowercase unknown global
-- is a genuine bug in this harness and must still read as nil.
local unknown = {}
local function install_unknown_tracker()
	setmetatable(_G, {
		__index = function(t, k)
			if type(k) == "string" and k:match("^%u") then
				unknown[k] = (unknown[k] or 0) + 1
				local f = function() end
				rawset(t, k, f)
				return f
			end
			return nil
		end,
	})
end

-- ---- load the real game code ----------------------------------------------

local loaded = {}
function dofile_once(path)
	if loaded[path] then return loaded[path] end
	local p = path:gsub("^data/scripts", REF)
	local chunk, err = loadfile(p)
	if not chunk then error("harness could not load " .. path .. ": " .. tostring(err)) end
	loaded[path] = chunk() or true
	return loaded[path]
end
dofile = dofile_once

make_env()
install_unknown_tracker()
dofile_once("data/scripts/gun/gun.lua")
dofile_once("data/scripts/gun/gun_actions.lua")

-- ---- instrumentation -------------------------------------------------------
--
-- gun.lua calls these through the global table, so replacing the globals after
-- load intercepts every internal call site too.

local trace, depth, wrapped_now = nil, 0, false

-- Per-cast deck bookkeeping (see DRAWN vs CONSUMED in the header).
local seen_slots = nil   -- start-of-cast deck, plus everything a wrap put back
local start_slots = nil  -- start-of-cast deck only
local after_slots = nil  -- deck at the end of the draw phase

-- The set of 1-based slots currently in the deck. deck_index is 0-based and is
-- the inventory position the card was added at, so it survives wraps and
-- reorders -- unlike the card's position in the deck array.
local function deck_slots()
	local set = {}
	for _, a in ipairs(deck) do set[(a.deck_index or 0) + 1] = true end
	return set
end

local function sorted_keys(set)
	local out = {}
	for k in pairs(set) do out[#out + 1] = k end
	table.sort(out)
	return out
end

-- Set by play_action so the action-body wrapper below can tell an ordinary
-- play from a DIRECT invocation (see the wrapper's note).
local announced = false

local real_play_action = play_action
play_action = function(action)
	announced = true
	if trace then
		trace[#trace + 1] = {
			id = action.id,
			slot = (action.deck_index or 0) + 1,
			depth = math.max(0, depth - ROOT_DEPTH),
			wrapped = wrapped_now or nil,
		}
	end
	return real_play_action(action)
end

-- Not every card that fires is PLAYED. The DIVIDE_* bodies read deck[1] and
-- call `data.action(...)` on it directly -- the card never reaches play_action,
-- never enters `hand`, and a play_action hook alone simply cannot see it (it is
-- still consumed: the deck is empty after "DIVIDE_2, LIGHT_BULLET" draws).
-- Miss it and the harness reports a phantom divergence on every wand holding a
-- divide -- a harness artifact that would read exactly like a mod bug.
--
-- So wrap every action body at the source, before clone_action copies the field
-- into any deck card, and record the invocations play_action did not announce.
-- A direct invocation has no deck card behind it here, so it carries no slot.
for _, a in ipairs(actions) do
	local body = a.action
	local id = a.id
	a.action = function(...)
		if announced then
			announced = false
		elseif trace then
			trace[#trace + 1] = { id = id, direct = true,
				depth = math.max(0, depth - ROOT_DEPTH), wrapped = wrapped_now or nil }
		end
		return body(...)
	end
end

local real_draw_actions = draw_actions
draw_actions = function(how_many, instant)
	depth = depth + 1
	local ok, err = pcall(real_draw_actions, how_many, instant)
	depth = depth - 1
	if not ok then error(err, 0) end
end

local real_draw_shot = draw_shot
draw_shot = function(shot, instant)
	depth = depth + 1
	local ok, err = pcall(real_draw_shot, shot, instant)
	depth = depth - 1
	-- Back at depth 0 = the root draw_shot has returned = the cast has finished
	-- drawing. Snapshot HERE: _handle_reload runs next and can refill the deck.
	if depth == 0 and trace then after_slots = deck_slots() end
	if not ok then error(err, 0) end
end

local real_move_discarded = move_discarded_to_deck
local wrap_count = 0
move_discarded_to_deck = function()
	local moved = #discarded > 0
	local r = real_move_discarded()
	-- The WRAP: a forced draw found the deck empty and pulled the discard back
	-- in. Two calls that are NOT wraps and must not be counted:
	--   * _handle_reload's, at the end of a recharge cycle -- hence depth > 0,
	--     i.e. only while cards are actually being drawn;
	--   * a forced draw with an EMPTY discard -- draw_action calls this
	--     unconditionally, so a lone trailing modifier "wraps" nothing into
	--     nothing. No card moves and none can be drawn, so there is nothing for
	--     the mod to mark wrapped; hence `moved`. (The engine does set
	--     start_reload there, but that is recharge timing, not deck structure.)
	if trace and depth > 0 and moved then
		wrap_count = wrap_count + 1
		wrapped_now = true
		-- Everything the wrap put back is now drawable by this cast, so it
		-- joins the set `drawn` is measured against.
		if seen_slots then
			for slot in pairs(deck_slots()) do seen_slots[slot] = true end
		end
	end
	return r
end

-- ---- driving a wand --------------------------------------------------------

local BIG_MANA = 1e9

-- Run `tokens` (ordered action ids) as a wand at `spells_per_cast`, for
-- `casts` casts. Returns { casts = { cast, ... }, wraps = n,
-- unsupported = { name, ... } or nil }, where each `cast` is the array part of
-- the play trace -- { {id, slot, depth, wrapped}, ... } -- carrying three
-- named fields alongside it:
--   cast.drawn      sorted 1-based slots the cast removed from the deck  <- diff this
--   cast.consumed   sorted slots in the deck at cast start and gone after (see header)
--   cast.wrapped    true if the deck wrapped mid-draw during this cast
--   cast.mana_spent BIG_MANA minus gun.lua's `mana` global right after the
--                   draw phase -- _start_shot(BIG_MANA) reset it to BIG_MANA
--                   at the top of this same cast, so the difference is this
--                   cast's actual spend, straight from the engine.
function M.run(tokens, spells_per_cast, casts, opts)
	opts = opts or {}
	casts = casts or 2
	for k in pairs(unknown) do unknown[k] = nil end

	_clear_deck(false)
	gun.actions_per_round = spells_per_cast or 1
	gun.shuffle_deck_when_empty = opts.shuffle or false
	gun.reload_time = 0
	state_from_game = {}
	ConfigGunActionInfo_Init(state_from_game)

	for i, id in ipairs(tokens) do
		_add_card_to_deck(id, i, (opts.uses and opts.uses[i]) or -1, true)
	end
	if #deck ~= #tokens then
		return { error = "unknown action id in deck (only " .. #deck
			.. " of " .. #tokens .. " cards were added)" }
	end

	local out = { casts = {} }
	wrap_count = 0
	for _ = 1, casts do
		trace, depth, wrapped_now = {}, 0, false
		start_slots = deck_slots()
		seen_slots = deck_slots()
		after_slots = nil
		local ok, err = pcall(function()
			_start_shot(BIG_MANA)
			_draw_actions_for_shot(true)
		end)
		if not ok then
			trace = nil
			return { error = tostring(err), casts = out.casts }
		end
		-- gun.lua's `mana` is a plain global (no setfenv here, so it's the
		-- same `mana` draw_action decrements) and _start_shot just reset it
		-- to BIG_MANA above, so BIG_MANA - mana is exactly this cast's
		-- spend -- cheap and safe: it reads state gun.lua already maintains,
		-- no new hook.
		trace.mana_spent = BIG_MANA - mana
		local after = after_slots or deck_slots()
		local drawn, consumed = {}, {}
		for slot in pairs(seen_slots) do
			if not after[slot] then drawn[slot] = true end
		end
		for slot in pairs(start_slots) do
			if not after[slot] then consumed[slot] = true end
		end
		trace.drawn = sorted_keys(drawn)
		trace.consumed = sorted_keys(consumed)
		trace.wrapped = wrapped_now
		out.casts[#out.casts + 1] = trace
		trace = nil
	end
	seen_slots, start_slots, after_slots = nil, nil, nil
	out.wraps = wrap_count

	local un = {}
	for k in pairs(unknown) do un[#un + 1] = k end
	table.sort(un)
	if #un > 0 then out.unsupported = un end
	return out
end

-- Compact one-line rendering of a run, for eyeballing and for diffs:
--   {LIGHT_BULLET} | {~DAMAGE >LIGHT_BULLET}
-- "~" marks a card drawn after a wrap, ">" one nesting level of forced draw.
function M.show(run)
	if run.error then return "ERROR: " .. run.error end
	local casts = {}
	for _, cast in ipairs(run.casts) do
		local parts = {}
		for _, e in ipairs(cast) do
			parts[#parts + 1] = (e.wrapped and "~" or "")
				.. string.rep(">", e.depth) .. e.id .. (e.direct and "*" or "")
		end
		casts[#casts + 1] = "{" .. table.concat(parts, " ") .. "}"
	end
	return table.concat(casts, " | ")
end

-- Per-cast slot sets, for the differential diff and for eyeballing:
--   {1,2,3}W | {4}      -- "W" marks the cast that wrapped
-- Uses `drawn` (see the header); pass "consumed" as `field` for the cross-check.
function M.show_consumed(run, field)
	if run.error then return "ERROR: " .. run.error end
	field = field or "drawn"
	local casts = {}
	for _, cast in ipairs(run.casts) do
		casts[#casts + 1] = "{" .. table.concat(cast[field] or {}, ",") .. "}"
			.. (cast.wrapped and "W" or "")
	end
	return table.concat(casts, " | ")
end

return M
