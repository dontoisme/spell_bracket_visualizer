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
	if not ok then error(err, 0) end
end

local real_move_discarded = move_discarded_to_deck
local wrap_count = 0
move_discarded_to_deck = function()
	-- The WRAP: a forced draw found the deck empty and pulled the discard back
	-- in. _handle_reload calls this too at the end of a cycle, which is NOT a
	-- wrap -- the flag below is only armed while a cast is drawing.
	if trace then
		wrap_count = wrap_count + 1
		wrapped_now = true
	end
	return real_move_discarded()
end

-- ---- driving a wand --------------------------------------------------------

local BIG_MANA = 1e9

-- Run `tokens` (ordered action ids) as a wand at `spells_per_cast`, for
-- `casts` casts. Returns { casts = { { {id, slot, depth, wrapped}, ... }, ... },
-- wraps = n, unsupported = { name, ... } or nil }.
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
		local ok, err = pcall(function()
			_start_shot(BIG_MANA)
			_draw_actions_for_shot(true)
		end)
		if not ok then
			trace = nil
			return { error = tostring(err), casts = out.casts }
		end
		out.casts[#out.casts + 1] = trace
		trace = nil
	end
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

return M
