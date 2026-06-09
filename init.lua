dofile_once( "data/scripts/lib/utilities.lua" )

-- all functions below are optional and can be left out

function OnModInit()
	print("[TestMod] Starting initialization...")
	ModLuaFileAppend("data/scripts/gun/gui.lua", "mods/testMod/files/gui/spell_brackets.lua")
	print("[TestMod] Finished initialization!")
end
