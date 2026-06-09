dofile("data/scripts/lib/mod_settings.lua") -- see this file for documentation on the settings API

local mod_id = "testMod"
mod_settings_version = 1
mod_settings = {
	{
		id = "show_grouping",
		ui_name = "Wand Structure Panel",
		ui_description = "While the inventory is open, show a Lisp-style tree of the\nactive wand's cast structure: what fires together each cast\n(multicasts, triggers, modifiers) and when the wand WRAPS.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_slot_brackets",
		ui_name = "Slot Brackets",
		ui_description = "Rainbow nesting brackets on the spell cards in the wand UI,\nSLIME-style: each group's span, multicast/trigger labels, and\nwand wrapping in orange.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
}

function ModSettingsUpdate( init_scope )
	mod_settings_update( mod_id, mod_settings, init_scope )
end

function ModSettingsGuiCount()
	return mod_settings_gui_count( mod_id, mod_settings )
end

function ModSettingsGui( gui, in_main_menu )
	mod_settings_gui( mod_id, mod_settings, gui, in_main_menu )
end
