-- Pure deck -> cast-structure simulator. No game APIs; unit-testable
-- (tools/test_wand_structure.py is a line-for-line Python mirror with tests).
--
-- Mirrors data/scripts/gun/gun.lua exactly (verified against the source):
--   * A CAST draws `spells_per_cast` (gun.actions_per_round) expressions off
--     one flat deck. These root draws pass instant_reload_if_empty=false:
--     if the deck is empty, the cast just ends (and the wand recharges).
--   * Every card-forced draw passes instant_reload_if_empty=true: a card whose
--     body calls draw_actions(N, true) (modifier chains, multicasts) or a
--     trigger payload (draw_shot(create_shot(N), true)). If the deck is empty
--     on a forced draw, the WAND WRAPS: the discard pile (cards cast earlier
--     this recharge cycle) moves back into the deck -- in slot order for
--     non-shuffle wands -- and drawing continues from the wand's start. A wrap
--     also sets start_reload, so the recharge cycle ends after that cast.
--   * Chaining is decided by meta.draws (from each card's action body), not
--     the action type: all PASSIVEs and nearly all MODIFIERs draw 1 (so they
--     prefix-attach), but so do some OTHER/UTILITY cards (ALPHA, I_SHOT, ...).
--     RANDOM_MODIFIER draws 0 and terminates a chain. draws=-1 (BURST_X)
--     gathers the whole remaining deck.
--
-- Input : tokens = ordered array of action_id strings (a wand's cards)
--         meta   = the table from files/structure_meta.lua
--         opts   = { spells_per_cast = N } (nil -> whole deck as one cast)
-- Output of M.simulate:
--   { casts = { { nodes = {...}, wrapped = bool }, ... }, wrapped = bool }
-- Node shapes (first/last = min/max 1-based slot index the expression touched,
-- including wrapped-in cards, so a wrapping node's span reaches back to the
-- wand's start; head = the node's OWN card's index, i.e. the span excluding
-- the leading modifier prefix -- Lisp-wise the modifiers sit outside the
-- group's parens):
--   leaf      { kind="leaf",      id, atype, modifiers={ids} }
--   multicast { kind="multicast", id, atype, group=N (-1 = rest of deck),
--               children={...}, modifiers={ids} }
--   trigger   { kind="trigger",   id, atype, trigger=kind, payload=N,
--               children={...}, modifiers={ids} }
-- A modifier chain that exhausts the deck with nothing left to wrap in
-- becomes a leaf with dangling=true. Nodes built across a wrap get wrap=true,
-- plus wfirst/wlast = min/max slot index of the cards drawn AFTER the wrap
-- (the wrapped-in segment at the wand's start), so renderers can show the
-- group as forward-span + return + wrapped-span. node.last stays the max
-- FORWARD index in practice, since wrapped indices precede the head.

local M = {}

local function meta_for(meta, id)
	return meta[id] or { type = "OTHER" }
end

-- A card chains (prefix-attaches, like a modifier) iff it force-draws exactly
-- one replacement card and isn't a trigger.
local function chains(m)
	return m.draws == 1 and m.payload == nil and m.type ~= "DRAW_MANY"
end

local function is_multicast(m)
	return m.draws ~= nil and (m.draws >= 2 or m.draws == -1)
end

function M.simulate(tokens, meta, opts)
	opts = opts or {}
	local spc = opts.spells_per_cast
	if spc ~= nil and spc < 1 then spc = 1 end

	local deck, discard, hand = {}, {}, {}
	for i, id in ipairs(tokens) do deck[#deck + 1] = { i = i, id = id } end

	local wrap_count = 0
	local wrapped_now = false -- this cast has wrapped; later draws are wrapped-in

	-- One draw off the deck. Forced draws (from a card's own draw_actions /
	-- trigger payload) wrap the discard pile back in when the deck is empty.
	local function draw(forced)
		if #deck == 0 then
			if forced and #discard > 0 then
				table.sort(discard, function(a, b) return a.i < b.i end)
				deck, discard = discard, {}
				wrap_count = wrap_count + 1
				wrapped_now = true
			else
				return nil
			end
		end
		local card = table.remove(deck, 1)
		if wrapped_now then card.w = true end
		hand[#hand + 1] = card
		return card
	end

	local parse_seq -- forward declaration

	local function parse_expr(forced)
		local wraps_before = wrap_count
		local mods, first, last = {}, nil, nil
		local wfirst, wlast = nil, nil -- span of wrapped-in cards (post-wrap)
		local function note(c)
			if first == nil or c.i < first then first = c.i end
			if last == nil or c.i > last then last = c.i end
			if c.w then
				if wfirst == nil or c.i < wfirst then wfirst = c.i end
				if wlast == nil or c.i > wlast then wlast = c.i end
			end
		end
		local card = draw(forced)
		if card == nil then return nil end
		local m = meta_for(meta, card.id)

		while chains(m) do
			mods[#mods + 1] = card.id
			note(card)
			card = draw(true)
			if card == nil then
				return { kind = "leaf", id = mods[#mods], atype = "MODIFIER",
					modifiers = mods, dangling = true, first = first, last = last,
					wfirst = wfirst, wlast = wlast,
					wrap = (wrap_count > wraps_before) or nil }
			end
			m = meta_for(meta, card.id)
		end

		note(card)
		local node = { id = card.id, atype = m.type, modifiers = mods, head = card.i }

		if is_multicast(m) then
			node.kind = "multicast"
			node.group = m.draws
			local count = m.draws
			if count == -1 then count = #deck end -- BURST_X: the rest of the deck
			node.children = parse_seq(count, true)
		elseif m.payload then
			node.kind = "trigger"
			node.trigger = m.trigger
			node.payload = m.payload
			node.children = parse_seq(m.payload, true)
		else
			node.kind = "leaf"
		end

		if node.children then
			for _, ch in ipairs(node.children) do
				if ch.first and ch.first < first then first = ch.first end
				if ch.last and ch.last > last then last = ch.last end
				if ch.wfirst and (wfirst == nil or ch.wfirst < wfirst) then wfirst = ch.wfirst end
				if ch.wlast and (wlast == nil or ch.wlast > wlast) then wlast = ch.wlast end
			end
		end
		node.first, node.last = first, last
		node.wfirst, node.wlast = wfirst, wlast
		if wrap_count > wraps_before then node.wrap = true end
		return node
	end

	parse_seq = function(limit, forced)
		local out = {}
		while limit == nil or #out < limit do
			local node = parse_expr(forced)
			if node == nil then break end
			out[#out + 1] = node
		end
		return out
	end

	local casts = {}
	local any_wrapped = false
	while #deck > 0 and #casts < 64 do -- cap: a wrap ends each cycle anyway
		local wraps_before = wrap_count
		hand = {}
		wrapped_now = false
		local nodes = parse_seq(spc, false)
		local wrapped = wrap_count > wraps_before
		casts[#casts + 1] = { nodes = nodes, wrapped = wrapped }
		for _, cd in ipairs(hand) do discard[#discard + 1] = cd end
		hand = {}
		if wrapped then
			-- start_reload: the recharge cycle ends after a wrapping cast;
			-- cards after this point never fire this cycle.
			any_wrapped = true
			break
		end
	end

	return { casts = casts, wrapped = any_wrapped }
end

-- Back-compat: whole deck as a single cast (the pre-simulation behavior).
function M.build(tokens, meta)
	local sim = M.simulate(tokens, meta, nil)
	return (sim.casts[1] and sim.casts[1].nodes) or {}
end

return M
