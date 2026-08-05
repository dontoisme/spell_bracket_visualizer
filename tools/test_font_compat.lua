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
-- The REAL reported font (Better Font (English), Workshop id 2098567286),
-- reproduced from the mod's own in-game probe: "MWli0 |[]" measures
-- 31.5 x 12.5 at scale 1.0 but 11.1 x 5.0 at 0.6 -- ratios 0.352 / 0.400
-- instead of 0.6. GuiText meanwhile ignores scale and draws at ~1.0, so any
-- layout computed at a fractional scale ends up ~2.8x too small for its text.
local function font_nonlinear()
	GuiGetTextDimensions = function(gui, text, scale)
		scale = scale or 1
		-- per-char metrics at 1.0, then the measured sub-linear shrink curve
		local w1, h1 = 3.5 * T.utf8_chars(text), 12.5
		if scale >= 1 then return w1 * scale, h1 * scale end
		return w1 * (scale * 0.587), h1 * (scale * 0.667)
	end
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

-- ---- faithful_scale: the actual fix ----------------------------------------
--
-- A font that scales linearly keeps the user's chosen size; one that doesn't
-- (GuiText would draw it at ~1.0 anyway) gets clamped to 1.0 so measuring and
-- drawing agree. This is what stops the reported off-screen overflow.

font_pixel_like()
for _, s in ipairs({ 0.5, 0.6, 0.75 }) do
	eq("faithful_scale keeps " .. s .. " on a linear font", T.faithful_scale(nil, s), s)
end
eq("faithful_scale passes 1.0 through", T.faithful_scale(nil, 1.0), 1.0)

font_nonlinear()
for _, s in ipairs({ 0.5, 0.6, 0.75 }) do
	eq("faithful_scale clamps " .. s .. " to 1.0 on the reported font",
		T.faithful_scale(nil, s), 1)
end
eq("faithful_scale leaves 1.0 alone on the reported font", T.faithful_scale(nil, 1.0), 1.0)

font_zero()
eq("faithful_scale clamps when the font measures zero", T.faithful_scale(nil, 0.6), 1)
font_nil()
eq("faithful_scale clamps when the font measures nil", T.faithful_scale(nil, 0.6), 1)

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
font_nonlinear();  run_panel(0.6); panel_asserts("reported font @0.6", 0.6)

-- ---- the reported bug itself, end to end ------------------------------------
--
-- Tiny/Small/Medium under the reported font used to size the panel from
-- sub-linear measurements while GuiText painted at ~1.0: in game that produced
-- a 63.7-GUI panel whose labels ran off the right edge of the screen. Whatever
-- size the user picks, the panel must end up sized for the text that is
-- actually drawn.

for _, requested in ipairs({ 0.5, 0.6, 0.75 }) do
	font_nonlinear()
	run_panel(requested)
	local tag = "reported font @" .. requested

	-- the clamp reached GuiText, so measure-size == draw-size
	local off = nil
	for _, t in ipairs(drawn.texts) do
		if t.scale ~= 1 then off = t.scale; break end
	end
	passck(tag .. ": text drawn at the clamped 1.0", off == nil,
		"a row drew at scale " .. tostring(off))

	-- and the box genuinely contains that 1.0-sized text
	local widest = 0
	for _, t in ipairs(drawn.texts) do
		local w = (GuiGetTextDimensions(nil, t.text, 1))
		if w > widest then widest = w end
	end
	passck(tag .. ": panel wide enough for the text actually drawn",
		drawn.ninepiece.w >= widest,
		"panel_w=" .. tostring(drawn.ninepiece.w) .. " < widest row " .. tostring(widest))
	passck(tag .. ": nothing runs off the right screen edge",
		drawn.ninepiece.x + drawn.ninepiece.w <= 640,
		"bg right edge " .. tostring(drawn.ninepiece.x + drawn.ninepiece.w))
end

-- Regression guard: the vanilla pixel font must keep honouring the user's
-- choice -- the clamp must never fire for the overwhelming majority of users.
for _, requested in ipairs({ 0.5, 0.6, 0.75 }) do
	font_pixel_like()
	run_panel(requested)
	local off = nil
	for _, t in ipairs(drawn.texts) do
		if t.scale ~= requested then off = t.scale; break end
	end
	passck("pixel-like font @" .. requested .. ": user's size preserved (no clamp)",
		off == nil, "drew at " .. tostring(off) .. " instead of " .. requested)
end

-- ---- verdict + the half a script can't do -----------------------------------

print(string.format("\n%d failure(s)", failures))
if failures == 0 then
	print([[
All layout-math checks pass. The other half needs the real engine:

  IN-GAME CHECKLIST (with the Better Font (English) mod, Workshop id
  2098567286, enabled -- or the language set to Japanese):
   1. Hold a wand, open the inventory. At Tiny/Small/Medium the panel must now
      auto-clamp to Large: a readable box with every label inside it, nothing
      running off the right edge of the screen.
   2. Rows must not overlap; labels must not be garbage glyphs.
   3. Settings -> Debug Info ON. The "scale fidelity" line should read
      "BROKEN, panel forced to Large" under this font -- that is the clamp
      reporting itself, not an error.
   4. VANILLA REGRESSION (no font mods, English): the same line must read
      "ok, fractional sizes honoured", and Tiny/Small/Medium must still render
      at their real sizes -- the clamp must never fire here.]])
end
os.exit(failures > 0 and 1 or 0)
