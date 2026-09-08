#!/usr/bin/env lua5.4
-- Validates the wand-structure panel's ROW CLAMP against the REAL
-- files/grouping_overlay.lua, by stubbing the game's Gui API and recording
-- what draw_panel actually draws.
--
--     lua tools/test_panel_rows.lua        (any Lua 5.1+ / LuaJIT)
--
-- What's at stake: a structure too long for the screen folds its tail into one
-- "... +N more" line. The "?" legend ("depends on game state when cast") is
-- appended LAST, so a naive tail-cut drops the legend while the "?" marks it
-- explains stay on screen above it -- unexplained. Rows may set sticky=true to
-- be held back from the cut and re-appended after it; the "+N more" count then
-- has to be over the CONTENT rows only, or it silently misreports how much was
-- hidden. Both halves are pure arithmetic, and both are off-by-one bait.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

-- ---- stub the game environment, then load the REAL overlay ------------------

function dofile_once(path)
	local rel = path:match("^mods/spell_bracket_visualizer/(.*)$")
	assert(rel, "unexpected dofile_once path: " .. tostring(path))
	return dofile(MOD .. "/" .. rel)
end

local drawn -- { texts = { {x, y, text, scale}, ... } }
function GuiZSet() end
function GuiColorSetForNextWidget() end
function GuiImageNinePiece() end
function GuiText(gui, x, y, text, scale)
	drawn.texts[#drawn.texts + 1] = { x = x, y = y, text = text, scale = scale }
end
-- Pixel-like font: linear in scale, so faithful_scale stays inert and the
-- clamp is exercised on its own rather than through the font-compat path.
function GuiGetTextDimensions(gui, text, scale)
	scale = scale or 1
	return 6 * #text * scale, 9 * scale
end

local overlay = dofile(MOD .. "/files/grouping_overlay.lua")
local T = assert(overlay._test, "grouping_overlay.lua did not export _test")

-- ---- tiny check harness (same conventions as the other tools/) -------------

local failures = 0
local function eq(what, got, want)
	if got == want then
		print("PASS " .. what)
	else
		failures = failures + 1
		print("FAIL " .. what)
		print("    expect " .. tostring(want))
		print("    got    " .. tostring(got))
	end
end

local TITLE = "Wand structure  (1/cast)"
local LEGEND = "? = depends on game state when cast"
local BRACKET_LEGEND = "[ ] = spells this card pulls from the wand"
local GREY = { 0.6, 0.6, 0.6 }

local function same_color(a, b)
	return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Drive the real draw_panel and return just the row labels it drew (the title
-- and the "|" nesting spines are not rows).
local function render(rows, sh)
	drawn = { texts = {} }
	local anchor = { boxes = { { top = 48, right = 400 } }, sel = 1 }
	T.draw_panel(nil, rows, TITLE, 640, sh or 360, anchor, 1.0)
	local labels = {}
	for _, t in ipairs(drawn.texts) do
		if t.text ~= TITLE and t.text ~= "|" then labels[#labels + 1] = t.text end
	end
	return labels
end

local function content_rows(n)
	local rows = {}
	for i = 1, n do
		rows[i] = { bars = {}, label = "spell " .. i, color = GREY }
	end
	return rows
end

local function with_legend(rows)
	rows[#rows + 1] = { bars = {}, label = LEGEND, color = GREY, sticky = true }
	return rows
end

local function count_more(labels)
	local n, text = 0, nil
	for _, l in ipairs(labels) do
		if l:match("^%.%.%. %+%d+ more$") then n = n + 1; text = l end
	end
	return n, text and tonumber(text:match("%+(%d+)")) or nil
end

-- ---- 1. short structure: nothing is cut, the legend sits last ---------------

local labels = render(with_legend(content_rows(3)), 360)
eq("short: every row drawn", #labels, 4)
eq("short: legend is last", labels[#labels], LEGEND)
eq("short: no '+N more' line", (count_more(labels)), 0)

-- ---- 2. long structure WITH the sticky legend -------------------------------
--
-- The legend must survive the cut and stay last, and the "+N more" count must
-- describe the CONTENT rows hidden -- not count the legend as content.

labels = render(with_legend(content_rows(200)), 360)
local n_more, hidden = count_more(labels)
eq("clamped: exactly one '+N more' line", n_more, 1)
eq("clamped: legend survives the cut", labels[#labels], LEGEND)

local shown = 0
for _, l in ipairs(labels) do
	if l ~= LEGEND and not l:match("^%.%.%. %+%d+ more$") then shown = shown + 1 end
end
eq("clamped: hidden count accounts for every content row", shown + hidden, 200)
eq("clamped: rows drawn are a prefix (first content row kept)", labels[1], "spell 1")
eq("clamped: '+N more' sits directly above the legend",
	labels[#labels - 1]:match("^%.%.%. %+%d+ more$") ~= nil, true)

-- ---- 3. long structure with NO sticky row (pre-existing behaviour) ----------
--
-- Regression guard: the sticky branch must not perturb the plain tail-cut.

labels = render(content_rows(200), 360)
n_more, hidden = count_more(labels)
eq("no-legend: exactly one '+N more' line", n_more, 1)
eq("no-legend: '+N more' is last", labels[#labels]:match("^%.%.%. %+%d+ more$") ~= nil, true)

shown = 0
for _, l in ipairs(labels) do
	if not l:match("^%.%.%. %+%d+ more$") then shown = shown + 1 end
end
eq("no-legend: hidden count accounts for every content row", shown + hidden, 200)

-- The legend is paid for out of the row budget, NOT added on top of it: the
-- clamped panel is the same height either way (it is clamped to the screen --
-- growing it would put a row off the bottom edge, which is the whole point of
-- the clamp). What the legend costs is one CONTENT row.
local with_l = render(with_legend(content_rows(200)), 360)
local without_l = render(content_rows(200), 360)
eq("legend does not grow the clamped panel", #with_l, #without_l)

local function content_shown(labels)
	local n = 0
	for _, l in ipairs(labels) do
		if l ~= LEGEND and not l:match("^%.%.%. %+%d+ more$") then n = n + 1 end
	end
	return n
end
eq("legend displaces exactly one content row",
	content_shown(with_l), content_shown(without_l) - 1)

-- ---- 4. two sticky footnotes both survive the clamp ------------------------
--
-- Track C's named "?" footnote and Track B's "[ ] = ..." legend are BOTH
-- sticky now (sim_rows can emit up to two trailing sticky rows). Both must
-- survive the "... +N more" cut, in order, and the count must still be over
-- the CONTENT rows only -- two sticky rows now cost two lines of the budget.

local function with_two_stickies(rows)
	rows[#rows + 1] = { bars = {}, label = LEGEND, color = GREY, sticky = true }
	rows[#rows + 1] = { bars = {}, label = BRACKET_LEGEND, color = GREY, sticky = true }
	return rows
end

-- The bracket legend is long enough that draw_panel's per-label width budget
-- (fit_label) can truncate it with a trailing "..." -- unrelated to the row
-- CLAMP this test is about -- so these checks match it by its stable prefix
-- rather than requiring the exact untruncated string.
labels = render(with_two_stickies(content_rows(200)), 360)
n_more, hidden = count_more(labels)
eq("two-sticky: exactly one '+N more' line", n_more, 1)
eq("two-sticky: footnote survives the cut", labels[#labels - 1], LEGEND)
eq("two-sticky: bracket legend survives the cut and stays last",
	labels[#labels]:match("^%[ %]") ~= nil, true)

shown = 0
for _, l in ipairs(labels) do
	if l ~= LEGEND and not l:match("^%[ %]") and not l:match("^%.%.%. %+%d+ more$") then
		shown = shown + 1
	end
end
eq("two-sticky: hidden count accounts for every content row", shown + hidden, 200)

-- ---- 5. T1.4 -- the named tier footnote + the always-on bracket legend -----

do
	local node = { kind = "leaf", id = "IF_ENEMY", atype = "OTHER", modifiers = {} }
	local sim = { casts = { { nodes = { node }, wrapped = false, mana = 0 } }, wrapped = false }
	local cfg = { spells_per_cast = 1 }
	local rows = T.sim_rows(sim, cfg, {}, { "ALPHA" })

	local footnote, legend
	for _, r in ipairs(rows) do
		if r.label:match("^%?%s*=") then footnote = r end
		if r.label == BRACKET_LEGEND then legend = r end
	end

	eq("tier footnote: present", footnote ~= nil, true)
	eq("tier footnote: names Alpha", footnote and footnote.label:find("Alpha", 1, true) ~= nil, true)
	eq("tier footnote: sticky", footnote and footnote.sticky, true)

	eq("bracket legend: present", legend ~= nil, true)
	eq("bracket legend: sticky", legend and legend.sticky, true)
end

-- ---- 6. T1.9 -- per-cast mana in the header, vs. mana_max ------------------

local function leaf(id)
	return { kind = "leaf", id = id, atype = "PROJECTILE", modifiers = {} }
end

local function find_header(rows)
	for _, r in ipairs(rows) do
		if r.header then return r end
	end
end

local function find_row(rows, label)
	for _, r in ipairs(rows) do
		if r.label == label then return r end
	end
end

local MANA_FOOTNOTE = "mana = cost of this cast; > max means part of it is discarded"

do
	-- Overflow: mana_max = 150, the cast costs 210.
	local sim = { casts = { { nodes = { leaf("LIGHT_BULLET") }, wrapped = false, mana = 210 } },
		wrapped = false }
	local cfg = { spells_per_cast = 1, mana_max = 150 }
	local rows = T.sim_rows(sim, cfg, {})
	local header = find_header(rows)
	eq("mana overflow: header shown", header ~= nil, true)
	eq("mana overflow: header text", header and header.label, "cast 1  mana 210  > max 150")
	eq("mana overflow: header uses WRAP_COLOR", same_color(header and header.color, T.WRAP_COLOR), true)
	eq("mana overflow: footnote present", find_row(rows, MANA_FOOTNOTE) ~= nil, true)
end

do
	-- No overflow: mana_max = 300, the same 210-mana cast.
	local sim = { casts = { { nodes = { leaf("LIGHT_BULLET") }, wrapped = false, mana = 210 } },
		wrapped = false }
	local cfg = { spells_per_cast = 1, mana_max = 300 }
	local rows = T.sim_rows(sim, cfg, {})
	local has_max = false
	for _, r in ipairs(rows) do
		if r.label:find("> max", 1, true) then has_max = true end
	end
	eq("mana no overflow: no '> max' anywhere", has_max, false)
	eq("mana no overflow: footnote absent", find_row(rows, MANA_FOOTNOTE), nil)
end

print("")
print(failures .. " failure(s)")
os.exit(failures == 0 and 0 or 1)
