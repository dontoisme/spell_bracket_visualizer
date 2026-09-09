#!/usr/bin/env lua5.4
-- Preview a wand's slot brackets in the terminal, without the game.
--
--     lua tools/preview_wand.lua CHAINSAW,CHAINSAW,BURST_2,SPITTER,BURST_2,SPITTER
--     lua tools/preview_wand.lua TNTBOX,TNTBOX,HORIZONTAL_ARC,...  --per-cast=2
--
-- Prints the delimiters as a Lisp line -- the notation the brackets are meant
-- to read as -- coloured with the ACTUAL rainbow the mod would draw:
--
--     [ Chainsaw, Chainsaw, [Double spell, Spitter [Double spell, Spitter]] ]
--
-- It drives the REAL collect_wand_delims and plan_delims (via _test), so the
-- nesting, the colours, the cast brackets, the single-spell suppression and the
-- wrap enclosure are exactly what the mod would put on the slot row. It cannot
-- check the parts calibrated against screenshots -- where the wand box sits, how
-- tall the slot row is, how the glyphs land on the card art -- so it answers
-- "is the structure right?", not "does it look right in game".
--
-- Options:
--   --per-cast=N   spells per cast (default 1)
--   --cols=A,B,..  real slot column of each card, for wands with empty slots
--                  (default: card i sits in column i-1)
--   --plain        no ANSI colour
--   --glyphs       also dump the raw glyph list (side, column, stack level)
--   --tier         wand structure confidence tier (exact/approximate/unknown) and
--                  which cards caused uncertainty, if any
--   --mana         mana cost per cast
--   --uses=SLOT:N,SLOT:N
--                  charge counts (uses_remaining) for depleted-spell tracking

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."

function dofile_once(path)
	local rel = path:match("^mods/spell_bracket_visualizer/(.*)$")
	assert(rel, "unexpected dofile_once path: " .. tostring(path))
	return dofile(MOD .. "/" .. rel)
end
-- grouping_overlay only calls these when it DRAWS; loading it needs them to
-- exist because the file is one chunk.
function GuiZSet() end
function GuiColorSetForNextWidget() end
function GuiImage() end
function GuiText() end
function GuiGetTextDimensions() return 0, 0 end

local meta = dofile(MOD .. "/files/structure_meta.lua")
local S = dofile(MOD .. "/files/wand_structure.lua")
local T = assert(dofile(MOD .. "/files/grouping_overlay.lua")._test,
	"grouping_overlay.lua did not return its _test exports")

-- ---- args ------------------------------------------------------------------

local spells, per_cast, cols_arg, plain, show_glyphs = nil, 1, nil, false, false
local show_tier, show_mana, uses_arg = false, false, nil
for _, a in ipairs(arg) do
	if a == "--plain" then plain = true
	elseif a == "--glyphs" then show_glyphs = true
	elseif a == "--tier" then show_tier = true
	elseif a == "--mana" then show_mana = true
	elseif a:match("^%-%-per%-cast=") then per_cast = tonumber(a:match("=(.+)")) or 1
	elseif a:match("^%-%-cols=") then cols_arg = a:match("=(.+)")
	elseif a:match("^%-%-uses=") then uses_arg = a:match("=(.+)")
	elseif a:match("^%-%-") then
		io.stderr:write("unknown option: " .. a .. "\n"); os.exit(2)
	else spells = a end
end
if not spells then
	io.stderr:write("usage: lua tools/preview_wand.lua SPELL,SPELL,... " ..
		"[--per-cast=N] [--cols=A,B,...] [--plain] [--glyphs] [--tier] [--mana] [--uses=SLOT:N,SLOT:N]\n")
	os.exit(2)
end

local tokens = {}
for id in spells:gmatch("[^,%s]+") do tokens[#tokens + 1] = id:upper() end
if #tokens == 0 then io.stderr:write("no spells given\n"); os.exit(2) end

local unknown = {}
for _, id in ipairs(tokens) do
	if not meta[id] then unknown[#unknown + 1] = id end
end
if #unknown > 0 then
	-- Not fatal: the simulator treats an unknown id as a plain projectile,
	-- which is also what it does for a modded spell in game. Say so, since an
	-- id typo would otherwise silently change the structure.
	io.stderr:write("warning: not in structure_meta (treated as a plain spell): "
		.. table.concat(unknown, ", ") .. "\n")
end

local cols, rows = {}, {}
if cols_arg then
	local i = 0
	for c in cols_arg:gmatch("[^,%s]+") do i = i + 1; cols[i] = tonumber(c) end
end
for i = 1, #tokens do
	cols[i] = cols[i] or (i - 1)
	rows[i] = 0
end

local uses = {}
if uses_arg then
	for pair in uses_arg:gmatch("[^,%s]+") do
		local slot, n = pair:match("^([^:]+):(.+)$")
		if not slot or not n then
			io.stderr:write("malformed --uses value: " .. pair .. "\n"); os.exit(2)
		end
		slot = tonumber(slot)
		n = tonumber(n)
		if not slot or not n then
			io.stderr:write("malformed --uses value: " .. pair .. "\n"); os.exit(2)
		end
		uses[slot] = n
	end
end

-- ---- colour ----------------------------------------------------------------

local function paint(text, c)
	if plain or not c then return text end
	return string.format("\27[38;2;%d;%d;%dm%s\27[0m",
		math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), text)
end

local function pretty(id)
	local s = tostring(id):gsub("_", " "):lower()
	return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- ---- build ------------------------------------------------------------------

local opts = { spells_per_cast = per_cast }
if next(uses) then opts.uses = uses end
local sim = S.simulate(tokens, meta, opts)
local groups = T.collect_wand_delims(sim, cols, rows)
local glyphs = T.plan_delims(groups)

-- card sitting in each displayed column
local card_at = {}
local maxcol = 0
for i, id in ipairs(tokens) do
	card_at[cols[i]] = pretty(id)
	if cols[i] > maxcol then maxcol = cols[i] end
end

-- glyphs by column and side; outermost (highest stack) is drawn furthest out,
-- so opens print outer -> inner and closes inner -> outer
local at = {}
for _, gl in ipairs(glyphs) do
	local k = gl.col .. ":" .. gl.side
	at[k] = at[k] or {}
	table.insert(at[k], gl)
end
for k, list in pairs(at) do
	local left = k:match(":(.+)$") == "left"
	table.sort(list, function(a, b)
		if left then return a.stack > b.stack else return a.stack < b.stack end
	end)
end

-- one piece per displayed column: its opening brackets, the card, its closing
-- brackets. An empty slot shows as "." -- it still occupies a column, and a
-- bracket can land on the gap beside it.
local out = {}
for col = 0, maxcol do
	local piece = {}
	for _, gl in ipairs(at[col .. ":left"] or {}) do piece[#piece + 1] = paint("[", gl.c) end
	piece[#piece + 1] = (card_at[col] or ".")
	for _, gl in ipairs(at[col .. ":right"] or {}) do piece[#piece + 1] = paint("]", gl.c) end
	out[#out + 1] = table.concat(piece)
end

-- ---- print ------------------------------------------------------------------

print()
print(string.format("%d spells, %d per cast, %d cast%s%s",
	#tokens, per_cast, #sim.casts, #sim.casts == 1 and "" or "s",
	sim.wrapped and "  -- WRAPS" or ""))

if show_tier then
	local tier, offenders = S.wand_tier(tokens, meta)
	print("tier: " .. tier)
	if #offenders > 0 then
		print("  uncertain: " .. table.concat(offenders, ", "))
	end
end

print()
print("  " .. table.concat(out, ", "))
print()

for ci, cast in ipairs(sim.casts) do
	local names = {}
	for _, n in ipairs(cast.nodes) do names[#names + 1] = pretty(n.id) end
	local suffix = ""
	if show_mana then
		local mana_str
		if cast.mana == math.floor(cast.mana) then
			mana_str = string.format("%d", cast.mana)
		else
			mana_str = string.format("%g", cast.mana)
		end
		suffix = suffix .. "  mana=" .. mana_str
	end
	if cast.spent and #cast.spent > 0 then
		suffix = suffix .. "  spent: " .. table.concat(cast.spent, ", ")
	end
	print(string.format("  cast %d: slots %s..%s%s   (%d spell%s: %s)%s",
		ci, tostring(cast.first), tostring(cast.last),
		cast.wfirst and ("  WRAPS in " .. cast.wfirst .. ".." .. cast.wlast) or "",
		#cast.nodes, #cast.nodes == 1 and "" or "s", table.concat(names, ", "), suffix))
end
print()
print(string.format("  %d delimiter%s:", #groups, #groups == 1 and "" or "s"))
for _, g in ipairs(groups) do
	print(string.format("    %s  columns %d..%d%s",
		paint("[ ]", g.c), g.ca, g.cb, g.wrap and "   the WRAP enclosure" or ""))
end

if show_glyphs then
	print()
	for i, gl in ipairs(glyphs) do
		print(string.format("    glyph %2d  %-5s col %2d  stack %d%s",
			i, gl.side, gl.col, gl.stack, gl.label and ("  \"" .. gl.label .. "\"") or ""))
	end
end
print()
