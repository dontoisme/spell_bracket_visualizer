-- Spell Bracket Visualizer
-- The spell inventory is drawn by the engine (no Lua draw hook exists), so we
-- can't paint over it. Instead we swap each vanilla spell's icon for a version
-- with a type-colored border. gun_actions.lua owns the `actions` table that
-- defines every spell's sprite, so we append our recolor pass onto it.

function OnModInit()
	ModLuaFileAppend("data/scripts/gun/gun_actions.lua", "mods/testMod/files/recolor_actions.lua")
end
