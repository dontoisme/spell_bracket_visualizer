-- Spell Bracket Visualizer
-- Lisp/SLIME-style wand structure: a companion panel and in-UI rainbow
-- brackets showing what fires together each cast and when the wand wraps.
--
-- (The original icon-recolor feature -- type-colored borders baked into every
-- spell icon -- was retired 2026-06-09: the rainbow brackets made it redundant
-- visual noise. See git history / docs/STATUS.md to revive it.)

-- Grouping/structure panel. Drawn every frame while the inventory is open.
-- Loaded lazily so a load error can't break mod startup.
local grouping = nil
local grouping_failed = false

function OnWorldPostUpdate()
	if grouping_failed then return end
	if grouping == nil then
		grouping = dofile_once("mods/testMod/files/grouping_overlay.lua")
		if type(grouping) ~= "table" then grouping_failed = true; return end
	end
	local ok, err = pcall(grouping.update)
	if not ok then
		grouping_failed = true
		print("[Spell Bracket Visualizer] grouping panel disabled: " .. tostring(err))
		if type(GamePrint) == "function" then
			pcall(GamePrint, "[Spell Bracket Visualizer] panel error: " .. tostring(err))
		end
	end
end
