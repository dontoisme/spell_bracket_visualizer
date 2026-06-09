-- Appended onto data/scripts/gun/gun_actions.lua by init.lua, so the vanilla
-- `actions` table (every spell and its `sprite`) is in scope here.
--
-- For each vanilla spell we have generated art for, point its sprite at our
-- bordered copy. Border color encodes the action type; see files/icons/.
-- Spells added by other mods are left untouched (not in known_ids).
--
-- This runs *inside* gun_actions.lua, so a thrown error here would break the
-- game's spell loading. Everything below is therefore defensive: any failure
-- leaves the vanilla icons in place rather than erroring out.

local function recolor()
	-- Settings default to on/corners if the settings API isn't reachable here.
	local show_colors = true
	if type(ModSettingGet) == "function" then
		local v = ModSettingGet("testMod.show_colors")
		if v ~= nil then show_colors = v end
	end
	if not show_colors then return end

	local style = "corners"
	if type(ModSettingGet) == "function" then
		local s = ModSettingGet("testMod.bracket_style")
		if s == "corners" or s == "frame" then style = s end
	end

	-- plain dofile (not dofile_once): gun_actions.lua can be re-run within the
	-- same lua context, and dofile_once would return nil on the second pass.
	local known = dofile("mods/testMod/files/known_ids.lua")
	if type(known) ~= "table" then return end

	local base = "mods/testMod/files/icons/" .. style .. "/"
	for _, action in ipairs(actions) do
		if action.id and known[action.id] then
			action.sprite = base .. action.id .. ".png"
		end
	end
end

local ok, err = pcall(recolor)
if not ok then
	print("[Spell Bracket Visualizer] recolor skipped: " .. tostring(err))
end
