dofile("data/scripts/lib/mod_settings.lua") -- see this file for documentation on the settings API

local mod_id = "spell_bracket_visualizer"
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
		ui_description = "Rainbow nesting brackets on the spell cards in the wand UI,\nlike nested code brackets: each group's span, and wand\nwrapping in orange.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_debug",
		ui_name = "Debug Info (for bug reports)",
		ui_description = "Show a small box (top-right) with your screen/GUI size and\nthe held wand's stats, plus magenta guide-lines on each wand box.\nIf the brackets or panel look wrong, turn this on, open your\nwand, and send the author a screenshot -- it shows your\nresolution, wand size, and where the mod thinks each row is.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	-- The heavy "Calibration Overlay" HUD (debug_boxes: rulers, mouse probes,
	-- plumb lines) was removed for the Workshop release; that code lives in git
	-- history. Re-add it if the box geometry ever drifts after a game update.
	-- The lightweight show_debug box above is the user-facing one.
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
