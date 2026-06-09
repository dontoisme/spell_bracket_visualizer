-- Spell Bracket Visualizer
-- The spell inventory is drawn by the engine (no Lua draw hook exists), so we
-- can't paint over it. Instead we swap each vanilla spell's icon for a version
-- with a type-colored border. gun_actions.lua owns the `actions` table that
-- defines every spell's sprite, so we append our recolor pass onto it.

function OnModInit()
	ModLuaFileAppend("data/scripts/gun/gun_actions.lua", "mods/testMod/files/recolor_actions.lua")
end

-- Grouping/structure panel (Lisp/SLIME-style). Drawn every frame while the
-- inventory is open. Loaded lazily so a load error can't break OnModInit.
local grouping = nil
local grouping_failed = false

-- TEMPORARY: one-shot in-game self-check (files/self_check.lua) that reports
-- whether the new gun_config / permanently_attached reads work on real wands.
-- false = disabled (errored or finished loading wrong); remove after verify.
local self_check = nil

function OnWorldPostUpdate()
	if self_check ~= false then
		if self_check == nil then
			local okl, m = pcall(dofile_once, "mods/testMod/files/self_check.lua")
			self_check = (okl and type(m) == "table") and m or false
		end
		if self_check then
			local okr = pcall(self_check.run)
			if not okr or self_check.done then self_check = false end
		end
	end

	if grouping_failed then return end
	if grouping == nil then
		grouping = dofile_once("mods/testMod/files/grouping_overlay.lua")
		if type(grouping) ~= "table" then grouping_failed = true; return end
	end
	local ok, err = pcall(grouping.update)
	if not ok then
		grouping_failed = true
		print("[Spell Bracket Visualizer] grouping panel disabled: " .. tostring(err))
		if type(GameAddFlagPersistent) == "function" then
			pcall(GameAddFlagPersistent, "sbv_panel_error")
		end
		if type(GamePrint) == "function" then
			pcall(GamePrint, "[Spell Bracket Visualizer] panel error: " .. tostring(err))
		end
	end
end
