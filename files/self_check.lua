-- TEMPORARY in-game self-check for the cast/wrap upgrade. Runs once per run
-- as soon as the player exists; exercises the new engine reads against the
-- player's real wands and reports two ways:
--   * GamePrint lines in-game, and
--   * a persistent flag whose NAME encodes the result -- flags are plain
--     files under save00/persistent/flags/, so the result can be read from
--     outside the game:  sbv_check_w<wands>_c<gun_config ok>_s<simulate ok>_
--     a<always-cast cards>_r<wands that wrap>
-- Remove this file (and its init.lua hook) once the feature is verified.

local wand_structure = dofile_once("mods/testMod/files/wand_structure.lua")
local meta = dofile_once("mods/testMod/files/structure_meta.lua") or {}

local M = { done = false }

local function flag(name)
	if type(GameAddFlagPersistent) == "function" then
		pcall(GameAddFlagPersistent, name)
	end
end

function M.run()
	if M.done then return end
	local players = EntityGetWithTag("player_unit")
	if not players or #players == 0 then return end
	M.done = true

	local wands, cfg_ok, sim_ok, always_n, wrapping = 0, 0, 0, 0, 0
	local items = GameGetAllInventoryItems(players[1]) or {}
	for _, it in ipairs(items) do
		if EntityHasTag(it, "wand") then
			wands = wands + 1

			local spc = nil
			local ab = EntityGetFirstComponentIncludingDisabled(it, "AbilityComponent")
			if ab and type(ComponentObjectGetValue2) == "function" then
				local ok, v = pcall(ComponentObjectGetValue2, ab, "gun_config", "actions_per_round")
				if ok and tonumber(v) and tonumber(v) >= 1 then
					spc = tonumber(v)
					cfg_ok = cfg_ok + 1
				end
			end

			local tokens = {}
			for _, child in ipairs(EntityGetAllChildren(it) or {}) do
				local iac = EntityGetFirstComponentIncludingDisabled(child, "ItemActionComponent")
				if iac then
					local aid = ComponentGetValue2(iac, "action_id")
					local perm = false
					local ic = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
					if ic then
						local ok, p = pcall(ComponentGetValue2, ic, "permanently_attached")
						perm = ok and p == true
					end
					if aid and aid ~= "" then
						if perm then always_n = always_n + 1 else tokens[#tokens + 1] = aid end
					end
				end
			end

			local ok, sim = pcall(wand_structure.simulate, tokens, meta,
				{ spells_per_cast = spc or 1 })
			if ok and type(sim) == "table" and sim.casts then
				sim_ok = sim_ok + 1
				if sim.wrapped then wrapping = wrapping + 1 end
			end
		end
	end

	local summary = string.format("wands=%d gun_config_ok=%d sim_ok=%d always_cast=%d wrapping=%d",
		wands, cfg_ok, sim_ok, always_n, wrapping)
	flag(string.format("sbv_check_w%d_c%d_s%d_a%d_r%d", wands, cfg_ok, sim_ok, always_n, wrapping))
	if type(GamePrint) == "function" then
		GamePrint("[Spell Bracket Visualizer] self-check: " .. summary)
		GamePrint("[Spell Bracket Visualizer] open the inventory to see the cast-structure panel")
	end
	print("[SBV] self-check: " .. summary)
end

return M
