#!/usr/bin/env lua5.4
-- Validates the v1.3.1 non-pixel-font fixes (docs/FONT_COMPAT.md) against the
-- REAL files/grouping_overlay.lua -- the exact Lua that ships in the mod --
-- by stubbing the game's Gui API and simulating three fonts:
--
--   pixel-like  : measures ~like the vanilla pixel font (regression guard --
--                 the floors must stay inert on the shipped configuration)
--   zero        : GuiGetTextDimensions returns 0,0 (the worst-case non-pixel
--                 font reading; pre-fix this collapsed the panel to an 8-GUI
--                 sliver at the right screen edge with 2-GUI row spacing)
--   nil         : GuiGetTextDimensions returns nothing at all
--
--     lua tools/test_font_compat.lua        (any Lua 5.1+ / LuaJIT)
--
-- This proves the layout math. It cannot prove how a real TTF measures in the
-- engine -- the in-game checklist printed at the end covers that half.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

-- ---- stub the game environment, then load the REAL overlay ------------------

-- grouping_overlay.lua resolves its own files via the game's dofile_once with
-- game-rooted paths; map those onto this checkout.
function dofile_once(path)
	local rel = path:match("^mods/spell_bracket_visualizer/(.*)$")
	assert(rel, "unexpected dofile_once path: " .. tostring(path))
	return dofile(MOD .. "/" .. rel)
end

-- Recording Gui stubs: draw_panel's calls are captured for assertions.
local drawn -- reset per draw_panel run: { ninepiece = {...}, texts = { {x,y,text,scale}, ... } }
function GuiZSet() end
function GuiColorSetForNextWidget() end
function GuiImageNinePiece(gui, id, x, y, w, h)
	drawn.ninepiece = { x = x, y = y, w = w, h = h }
end
function GuiText(gui, x, y, text, scale)
	drawn.texts[#drawn.texts + 1] = { x = x, y = y, text = text, scale = scale }
end
-- Overridden per font scenario below.
function GuiGetTextDimensions(gui, text, scale) return 0, 0 end

local overlay = dofile(MOD .. "/files/grouping_overlay.lua")
assert(type(overlay) == "table" and overlay._test,
	"grouping_overlay.lua did not return its _test exports")
local T = overlay._test

-- ---- tiny check harness (same conventions as test_wand_structure.lua) -------

local failures = 0
local function passck(name, ok, detail)
	if ok then
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
	end
end
local function eq(name, got, want)
	passck(name, got == want, tostring(got) .. " ~= " .. tostring(want))
end

-- ---- the three fonts --------------------------------------------------------

local function font_pixel_like()
	-- ~vanilla pixel font: 6 GUI/char advance, 9 GUI tall, scales linearly
	GuiGetTextDimensions = function(gui, text, scale)
		scale = scale or 1
		return 6 * T.utf8_chars(text) * scale, 9 * scale
	end
end
local function font_zero()
	GuiGetTextDimensions = function() return 0, 0 end
end
local function font_nil()
	GuiGetTextDimensions = function() return nil end
end

-- ---- UTF-8 helpers (fit_label used to byte-trim and split Japanese glyphs) --

eq("utf8_chars: ascii", T.utf8_chars("hello"), 5)
eq("utf8_chars: japanese", T.utf8_chars("光の弾"), 3)
eq("utf8_chars: mixed", T.utf8_chars("a光b"), 3)
eq("trim_last_char: ascii", T.trim_last_char("abc"), "ab")
eq("trim_last_char: japanese drops whole glyph", T.trim_last_char("a光"), "a")
eq("trim_last_char: japanese-only", T.utf8_chars(T.trim_last_char("光の")), 1)

-- ---- text_dims: floors engage only on degenerate readings -------------------

font_pixel_like()
local w, h = T.text_dims(nil, "abcd", 0.6)
eq("text_dims passthrough w (pixel-like untouched)", w, 6 * 4 * 0.6)
eq("text_dims passthrough h (pixel-like untouched)", h, 9 * 0.6)

font_zero()
w, h = T.text_dims(nil, "abcdefghij", 0.6)
eq("text_dims floor w (3 GUI/char)", w, 10 * 3 * 0.6)
eq("text_dims floor h (6 GUI)", h, 6 * 0.6)

font_nil()
w, h = T.text_dims(nil, "ab", 1)
eq("text_dims survives nil w", w, 6)
eq("text_dims survives nil h", h, 6)

-- ---- fit_label: terminates and keeps glyphs whole under a broken font -------

font_zero()
local out = T.fit_label(nil, string.rep("光", 50), 0.6, 20)
passck("fit_label terminates on zero-measuring font", out:sub(-3) == "...")
passck("fit_label never splits a multi-byte glyph",
	#out:sub(1, #out - 3) % 3 == 0, "trailing partial UTF-8 sequence")

font_pixel_like()
eq("fit_label passthrough when it fits", T.fit_label(nil, "short", 1, 100), "short")

-- ---- PANEL_SCALE_MAP: the Large escape hatch exists -------------------------

eq("PANEL_SCALE_MAP.large is 1.0 (font-mod escape hatch)", T.PANEL_SCALE_MAP.large, 1.0)
passck("settings.lua offers the large option",
	assert(io.open(MOD .. "/settings.lua")):read("*a"):find('"large"') ~= nil)

-- ---- draw_panel under each font: the reported symptom must not reproduce ----
--
-- The Workshop reports: panel "compressed and smaller then it should", a
-- sliver at the right screen edge. Drive the REAL draw_panel and assert the
-- panel background keeps a usable width and the rows keep readable spacing.
-- Pre-fix, the zero font produced panel_w = 8 (2x padding only) and 2-GUI row
-- pitch; the floors must hold both well above that in every scenario.

local function valid_utf8(s)
	local i = 1
	while i <= #s do
		local b = s:byte(i)
		local n = b < 0x80 and 0 or b >= 0xF0 and 3 or b >= 0xE0 and 2
			or b >= 0xC0 and 1 or -1
		if n == -1 then return false end -- stray continuation byte
		for j = 1, n do
			local c = s:byte(i + j)
			if not c or c < 0x80 or c >= 0xC0 then return false end
		end
		i = i + n + 1
	end
	return true
end

local function run_panel(scale)
	drawn = { texts = {} }
	local rows = {
		{ bars = {}, label = "cast 1", color = { 1, 1, 1 }, header = true },
		{ bars = { { 1, 1, 1 } }, label = "Spark Bolt With Trigger", color = { 1, 1, 1 } },
		{ bars = { { 1, 1, 1 }, { 1, 1, 1 } }, label = "光の弾 (localized name)", color = { 1, 1, 1 } },
		{ bars = { { 1, 1, 1 } }, label = "Magic Missile", color = { 1, 1, 1 } },
	}
	-- sw/sh = the common GUI 640x360; one wand box selected, wide enough
	-- (right=400) that the panel's width budget is genuinely constrained
	local anchor = { boxes = { { top = 48, right = 400 } }, sel = 1 }
	T.draw_panel(nil, rows, "Wand structure  (1/cast)", 640, 360, anchor, scale)
	return rows
end

local function panel_asserts(font_name, scale)
	local p = drawn.ninepiece
	passck(font_name .. ": panel background drawn", p ~= nil)
	if not p then return end
	-- width: never the pre-fix 8-GUI sliver; the title alone must keep it open
	passck(font_name .. ": panel width usable (was 8 pre-fix)", p.w >= 40,
		"panel_w=" .. tostring(p.w))
	-- position: right-anchored NEAR the edge is by design; it must not hang
	-- off-screen or wander left of the screen middle
	passck(font_name .. ": panel right edge on-screen",
		p.x + p.w <= 640 and p.x + p.w >= 320,
		"bg spans " .. tostring(p.x) .. ".." .. tostring(p.x + p.w))
	-- row spacing: consecutive text rows at least ~a glyph apart (was 2 GUI
	-- pre-fix under the zero font -- rows stacked onto each other)
	local min_pitch, prev = math.huge, nil
	for _, t in ipairs(drawn.texts) do
		if t.y ~= prev then -- spine bars share the row's y; count distinct rows
			if prev then min_pitch = math.min(min_pitch, t.y - prev) end
			prev = t.y
		end
	end
	passck(font_name .. ": rows don't overlap (pitch >= 5 GUI, was 2 pre-fix)",
		min_pitch >= 5, "min pitch=" .. tostring(min_pitch))
	-- every drawn (possibly truncated) label must still be valid UTF-8: the
	-- old byte-trimming fit_label split Japanese glyphs mid-sequence
	local bad = nil
	for _, t in ipairs(drawn.texts) do
		if not valid_utf8(t.text) then bad = t.text; break end
	end
	passck(font_name .. ": all drawn text is valid UTF-8 (no split glyphs)",
		bad == nil, "invalid: " .. tostring(bad))
end

font_pixel_like(); run_panel(0.6); panel_asserts("pixel-like font @0.6", 0.6)
font_zero();       run_panel(0.6); panel_asserts("zero font @0.6", 0.6)
font_nil();        run_panel(0.6); panel_asserts("nil font @0.6", 0.6)
font_zero();       run_panel(1.0); panel_asserts("zero font @Large(1.0)", 1.0)

-- ---- verdict + the half a script can't do -----------------------------------

print(string.format("\n%d failure(s)", failures))
if failures == 0 then
	print([[
All layout-math checks pass. The other half needs the real engine:

  IN-GAME CHECKLIST (with the Better Font (English) mod, Workshop id
  2098567286, enabled -- or the language set to Japanese):
   1. Hold a wand, open the inventory. The structure panel should sit at the
      right edge (by design) but be a readable box, not a squished sliver.
   2. Rows must not overlap; labels must not be garbage glyphs.
   3. Settings -> Wand Structure Panel: Text Size -> Large. Text should be
      crisp at every font.
   4. Settings -> Debug Info ON: screenshot the top-right box. The "font
      probe" line shows the raw engine measurements -- with the vanilla pixel
      font the @0.6 numbers are ~0.6x the @1.0 numbers and none are near 0.
      Post that screenshot on the Workshop thread to confirm the diagnosis.]])
end
os.exit(failures > 0 and 1 or 0)
