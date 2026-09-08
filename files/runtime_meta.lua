-- Runtime spell metadata: the game's own live `actions` table as a FALLBACK
-- layer beneath files/structure_meta.lua.
--
-- Why (docs/ADVANCED_SCENARIOS_PLAN.md 3 A1, Night's report of Sep 2):
-- structure_meta.lua is generated from vanilla gun_actions.lua, so a spell some
-- OTHER mod appended with
--     ModLuaFileAppend("data/scripts/gun/gun_actions.lua", ...)
-- is unknown to it. wand_structure's meta_for() then answers {type="OTHER"},
-- i.e. "a leaf that ends its cast" -- so a modded MODIFIER breaks the cast in
-- two and a modded multicast gathers nothing. That is exactly the "several
-- casts where only one exists" bug.
--
-- Every spell the game knows -- vanilla and modded alike -- is an entry in the
-- global `actions` table (a plain global assignment at gun_actions.lua:4). We
-- read it once, lazily, on the first M.update() (all mods have finished
-- appending by then) and derive a coarse record from the entry's declared
-- `type`. That record is deliberately weaker than a generated one: we know the
-- action's TYPE, not its body, so the tier is "approximate" or "unknown" and
-- never "exact" (2's tier table).
--
--   MODIFIER / PASSIVE          -> draws=1        approximate
--   DRAW_MANY                   -> no draw count  unknown
--   PROJECTILE/STATIC_/MATERIAL -> leaf, rp       approximate (could be a trigger)
--   UTILITY / OTHER             -> leaf           unknown
--
-- Loading gun_actions.lua inside our VM is cheap and safe: the file is one
-- enormous table constructor, and every `action = function() ... end` body is
-- only CONSTRUCTED, never called. It does need gun_enums.lua first (for the
-- ACTION_TYPE_* constants it indexes at file scope); its own two dofile_once
-- deps (procedural/gun_action_utils.lua, lib/utilities.lua) are pulled in by
-- the file itself. Verified offline against .gun_ref/ in
-- tools/test_runtime_meta.lua: no other file-scope global is required.
--
-- Everything here is failure-tolerant: any error leaves M.runtime empty and
-- M.status = "failed: ...", and M.merged() then degrades to plain
-- structure_meta -- today's behavior exactly.

local M = {}

-- id -> { type=<NAME string>, name=, mana=, rp= }
M.runtime = {}
M.status = "not loaded"
M.count = 0

-- ACTION_TYPE_* numeric value -> the NAME structure_meta.lua uses. Mirrors
-- data/scripts/gun/gun_enums.lua; the live globals override this at load time
-- so a future engine renumber follows the game rather than this table.
local DEFAULT_TYPE_NAMES = {
	[0] = "PROJECTILE",
	[1] = "STATIC_PROJECTILE",
	[2] = "MODIFIER",
	[3] = "DRAW_MANY",
	[4] = "MATERIAL",
	[5] = "OTHER",
	[6] = "UTILITY",
	[7] = "PASSIVE",
}

local TYPE_NAMES = { "PROJECTILE", "STATIC_PROJECTILE", "MODIFIER", "DRAW_MANY",
	"MATERIAL", "OTHER", "UTILITY", "PASSIVE" }

-- gun.lua's ACTION_MANA_DRAIN_DEFAULT: a nil `mana` costs 10, not 0 (5).
local MANA_DEFAULT = 10

-- Build value->name from the live ACTION_TYPE_* globals when they exist,
-- falling back to the enum as shipped.
local function type_name_map()
	local map = {}
	for k, v in pairs(DEFAULT_TYPE_NAMES) do map[k] = v end
	for _, nm in ipairs(TYPE_NAMES) do
		local v = rawget(_G, "ACTION_TYPE_" .. nm)
		if type(v) == "number" then map[v] = nm end
	end
	return map
end

-- Walk an `actions` array into M.runtime. Pure apart from writing M.runtime /
-- M.count; exposed for tests via M._test.
local function walk_actions(list)
	local map = type_name_map()
	local out, n = {}, 0
	for i = 1, #list do
		local a = list[i]
		if type(a) == "table" and type(a.id) == "string" then
			local rp = nil
			local rps = a.related_projectiles
			if type(rps) == "table" then rp = rps[2] or 1 end
			out[a.id] = {
				type = map[a.type] or "OTHER",
				name = (type(a.name) == "string") and a.name or nil,
				mana = tonumber(a.mana) or MANA_DEFAULT,
				rp   = rp,
			}
			n = n + 1
		end
	end
	M.runtime = out
	M.count = n
	return out
end

-- Idempotent. Pass `injected` (an actions-shaped array) to skip the game files
-- entirely -- that is how the tests drive this without Noita.
function M.load(injected)
	if injected ~= nil then
		M.fallbacks = {}
		local ok, err = pcall(walk_actions, injected)
		M.status = ok and "ok" or ("failed: " .. tostring(err))
		if not ok then M.runtime, M.count = {}, 0 end
		M.loaded = true
		return M.status
	end
	if M.loaded then return M.status end
	M.loaded = true
	M.fallbacks = {}
	local ok, err = pcall(function()
		if type(dofile_once) ~= "function" then
			error("dofile_once unavailable (not running in Noita)", 0)
		end
		-- enums FIRST: gun_actions.lua indexes ACTION_TYPE_* at file scope.
		dofile_once("data/scripts/gun/gun_enums.lua")
		dofile_once("data/scripts/gun/gun_actions.lua")
		local list = rawget(_G, "actions")
		if type(list) ~= "table" then error("global `actions` is not a table", 0) end
		walk_actions(list)
	end)
	if ok then
		M.status = "ok"
	else
		M.status = "failed: " .. tostring(err)
		M.runtime, M.count = {}, 0
	end
	return M.status
end

-- A runtime record -> a structure_meta-shaped record. Pure. See the tier table
-- at the top of this file / 3 A1 of the plan.
function M.type_fallback(rec)
	if type(rec) ~= "table" then return nil end
	local t = rec.type or "OTHER"
	local out = { type = t, name = rec.name, mana = rec.mana or MANA_DEFAULT }
	if t == "MODIFIER" or t == "PASSIVE" then
		-- The overwhelmingly common shape: chains onto the next card.
		out.draws = 1
		out.tier = "approximate"
	elseif t == "DRAW_MANY" then
		-- We know it multicasts; we do NOT know how many. No `draws` at all --
		-- guessing a count is exactly the "false results" complaint.
		out.tier = "unknown"
	elseif t == "PROJECTILE" or t == "STATIC_PROJECTILE" or t == "MATERIAL" then
		out.rp = rec.rp
		out.tier = "approximate" -- a leaf here, but it could be a trigger
	else -- UTILITY / OTHER: bodies do arbitrary things to the deck
		out.tier = "unknown"
	end
	return out
end

-- The table wand_structure.simulate should be handed: structure_meta first,
-- the runtime read underneath. A metatable, not a copy -- meta_for() only ever
-- does `meta[id]`, so there is no reason to duplicate 422 entries every frame.
-- Fallback records are built once per id and cached.
function M.merged(structure_meta)
	structure_meta = structure_meta or {}
	M._structure = structure_meta
	M.fallbacks = M.fallbacks or {}
	local fallbacks = M.fallbacks
	return setmetatable({}, { __index = function(_, id)
		local m = structure_meta[id]
		if m then return m end
		local c = fallbacks[id]
		if c ~= nil then
			if c == false then return nil end
			return c
		end
		local r = M.runtime[id]
		local f = r and M.type_fallback(r) or nil
		fallbacks[id] = (f == nil) and false or f
		return f
	end })
end

-- "meta" | "runtime" | nil -- which layer answered for this id (debug box).
function M.source(id)
	local sm = M._structure
	if sm and sm[id] then return "meta" end
	if M.runtime[id] then return "runtime" end
	return nil
end

-- One line for the debug readout.
function M.status_line()
	if M.status == "ok" then
		return string.format("runtime actions: %d loaded (ok)", M.count)
	end
	return "runtime actions: " .. tostring(M.status)
end

M._test = { walk_actions = walk_actions, MANA_DEFAULT = MANA_DEFAULT }

return M
