dofile("data/scripts/lib/mod_settings.lua") -- see this file for documentation on the settings API

local mod_id = "testMod"
mod_settings_version = 1
mod_settings = {
	{
		id = "show_colors",
		ui_name = "Colored Brackets",
		ui_description = "Frame each spell with a color based on its action type\n(projectile, modifier, material, ...).",
		value_default = true,
		scope = MOD_SETTING_SCOPE_NEW_GAME,
	},
	{
		id = "bracket_style",
		ui_name = "Bracket Style",
		ui_description = "Corner brackets (subtle) or a full frame (bold).",
		value_default = "corners",
		values = {
			{ "corners", "Corner brackets" },
			{ "frame", "Full frame" },
		},
		scope = MOD_SETTING_SCOPE_NEW_GAME,
	},
	{
		id = "show_grouping",
		ui_name = "Wand Structure Panel",
		ui_description = "While the inventory is open, show a Lisp-style tree of the\nactive wand's cast structure (multicasts, triggers, modifiers).",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_slot_brackets",
		ui_name = "Slot Brackets",
		ui_description = "Draw grouping brackets directly under the spell slots in the\nwand UI (experimental; alignment may vary by resolution).",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
}

-- Settings take effect when the spell list loads at the start of a run, so they
-- use NEW_GAME scope: change them in the menu, then start (or restart) a run.
function ModSettingsUpdate( init_scope )
	mod_settings_update( mod_id, mod_settings, init_scope )
end

function ModSettingsGuiCount()
	return mod_settings_gui_count( mod_id, mod_settings )
end

function ModSettingsGui( gui, in_main_menu )
	mod_settings_gui( mod_id, mod_settings, gui, in_main_menu )
end
