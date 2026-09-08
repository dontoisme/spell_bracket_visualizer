-- Pure deck -> cast-structure simulator. No game APIs; unit-testable
-- Tested by tools/test_wand_structure.lua (runs THIS file under Lua -- the
-- primary test) with tools/test_wand_structure.py as a Python cross-check mirror.
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
--   * The DIVIDE_* spells chain WITHOUT a forced draw (meta chain=true):
--     their bodies read deck[1] and invoke its action directly, never calling
--     draw_actions() -- so "Divide By N" prefixes the next card like a
--     modifier, but an empty deck means it does nothing: no wrap, ever.
--   * The ADD_TRIGGER family SCANS (meta scan=true). The body steps forward
--     over MODIFIER/PASSIVE/OTHER/DRAW_MANY cards, running each modifier
--     inline against the trigger projectile, and lands on the first card that
--     is none of those. If that card carries related_projectiles (meta rp), the
--     body removes the WHOLE scan from the deck -- stepped-over cards and
--     projectile together -- directly, with no draw_actions() call, so it can
--     never wrap; the projectile then draws rp 1-card payloads. If nothing
--     projectile-ish is left in the deck afterwards the body casts the card
--     plainly and spawns no trigger; if the scan runs off the end of the deck,
--     or lands on a card with no related projectile, it consumes nothing.
--   * A DEPLETED card (uses_remaining == 0) is RETRIED PAST, not skipped over
--     and not filtered out of the deck beforehand. draw_action() pops it,
--     pushes it to the discard pile and returns false without playing it;
--     draw_actions() then runs `while #deck > 0 do if draw_action() then
--     break end end`, so the draw is re-attempted on the next card and the
--     depleted card does NOT count toward N. Two consequences the simulator
--     has to carry, and the reason a pre-filter cannot express this:
--       - the depleted card WAS removed from the deck. It is part of what the
--         cast consumed (cast span, `slots` trace, and the discard pile a
--         later wrap pulls back in), it just never fires and never appears in
--         a node.
--       - THE RETRY CANNOT WRAP. Its loop is guarded on `#deck > 0` and never
--         reaches draw_action's instant_reload_if_empty path, so if the deck
--         empties during the retry that draw is silently LOST and the wand
--         does NOT wrap for it. Only the FIRST attempt of each draw can wrap.
--     The same draw_action path handles a card the caster cannot afford, so
--     mana exhaustion will inherit this model unchanged.
--
-- Input : tokens = ordered array of action_id strings (a wand's cards)
--         meta   = the table from files/structure_meta.lua
--         opts   = { spells_per_cast = N } (nil -> whole deck as one cast),
--                  plus { trace = true } to add each cast's raw slot list --
--                  used only by tools/test_gun_differential.lua, which diffs
--                  it against what Noita's own gun.lua takes out of the deck,
--                  plus { uses = { [slot] = uses_remaining } } -- the live
--                  charge counts, sparse: an absent slot means "not depleted".
--                  M.card_fires decides; only 0 is depleted.
-- Output of M.simulate:
--   { casts = { { nodes = {...}, wrapped = bool,
--                 first, last, wfirst, wlast,
--                 mana = N -- total mana this cast's drawn cards cost (a
--                          -- negative-mana card, e.g. Add Mana, subtracts),
--                 spent = { i, ... } -- slots this cast popped that were
--                                    -- DEPLETED: consumed, never fired, in no
--                                    -- node. Absent when there are none. A
--                                    -- cast whose every draw hit a depleted
--                                    -- card is a real cast with nodes = {}
--                                    -- and a non-empty spent list.
--                 slots = { i, ... } -- opts.trace only: every slot the cast
--                                    -- drew or directly consumed (wrapped-in
--                                    -- AND depleted cards included), sorted
--               }, ... }, wrapped = bool }
-- A cast's first/last/wfirst/wlast are its own slot span, split the same way a
-- node's is (forward run, then the wrapped-in run at the wand's start), so a
-- renderer can delimit the cast itself -- the cards that fire SIMULTANEOUSLY.
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
-- (the wrapped-in segment at the wand's start) and ffirst/flast = the same for
-- the cards drawn BEFORE it. first/last span BOTH, so on a wrapping node they
-- reach back to the wand's start; a renderer that wants only the run this
-- expression occupies going forward must use flast, not last (a wrap can pull
-- in MORE cards than precede the head, and then last is a wrapped index).

local M = {}

-- Will a card with this many uses left actually fire? Used by simulate() via
-- opts.uses on every pop off the deck: a card that does not fire is discarded
-- unplayed and the draw is retried on the next card (see the header). The engine
-- test is literally `== 0`, so only 0 is depleted: -1 = unlimited, -2 =
-- unlimited-unlimited, and any positive count all keep. Pure + exported so the
-- test harnesses cover the rule without game APIs (a nil uses count -- an absent
-- slot, or an unreadable field -- keeps the card).
function M.card_fires(uses_remaining)
	return uses_remaining ~= 0
end

-- The 8 Greek alphabet spells RE-CAST cards by position from the deck/hand/discard
-- piles (verified in gun_actions.lua): Alpha/Gamma/Tau copy a neighbour
-- (deck[1]/deck[#deck]/...), Omega/Mu/Phi/Sigma re-cast the discard pile, Zeta
-- builds its own option set -- and a copy invokes the card's action body directly,
-- bypassing draw_action's uses_remaining check, so a Greek can fire a card that is
-- depleted. That used to be the reason for a "keep depleted cards on Greek wands"
-- exception to a pre-simulation filter; the filter is GONE (the simulator keeps
-- every card and retries past the depleted ones, per the header), so the exception
-- is obsolete. This list survives only because the confidence tiering needs to know
-- which wands hold a Greek -- copy-by-position is what it cannot follow.
M.GREEK_SPELLS = {
	ALPHA = true, GAMMA = true, TAU = true, OMEGA = true,
	MU = true, PHI = true, SIGMA = true, ZETA = true,
}

-- Does this id list (a wand's action_ids, deck + always-cast) contain a Greek spell?
function M.has_greek(ids)
	for _, id in ipairs(ids) do
		if M.GREEK_SPELLS[id] then return true end
	end
	return false
end

-- ---- confidence tiers (docs/ADVANCED_SCENARIOS_PLAN.md 2) ----------------
-- How much of a card's deck behaviour this simulator can actually claim to
-- know. "exact" = the record captures the body's deck effects and they are
-- deterministic; "approximate" = modeled but position- or state-dependent
-- (the Greeks that copy live, the IF_* branches, the random family);
-- "unknown" = no usable record at all (ZETA, or a modded id we never saw).
-- Ordered so a wand's tier is simply the worst of its cards'.
M.TIER_RANK = { exact = 0, approximate = 1, unknown = 2 }

-- Tier of one metadata record. A missing record is "unknown" (the id is not in
-- structure_meta and the runtime layer could not classify it either). An
-- absent `tier` field means exact -- except on a record that declares itself
-- `dynamic`, which is at least approximate by definition: the generator always
-- sets both, but a hand-written or runtime-built record might set only one.
function M.tier(rec)
	if rec == nil then return "unknown" end
	local t = rec.tier
	if t == nil then
		return rec.dynamic ~= nil and "approximate" or "exact"
	end
	if t == "exact" and rec.dynamic ~= nil then return "approximate" end
	return t
end

-- The tier of a whole wand: the worst tier among its ids, plus the ids that
-- are responsible (worse than exact), de-duplicated in order of first
-- appearance so the panel footnote can name them. `meta` is indexed directly,
-- so the runtime_meta merged table's __index fallback participates.
function M.wand_tier(ids, meta)
	local worst, offenders, seen = "exact", {}, {}
	for _, id in ipairs(ids) do
		local t = M.tier(meta[id])
		if t ~= "exact" then
			if not seen[id] then
				seen[id] = true
				offenders[#offenders + 1] = id
			end
			if M.TIER_RANK[t] > M.TIER_RANK[worst] then worst = t end
		end
	end
	return worst, offenders
end

-- gun.lua's ACTION_MANA_DRAIN_DEFAULT: a card with no `mana` costs 10, not 0.
local MANA_DEFAULT = 10

local function meta_for(meta, id)
	return meta[id] or { type = "OTHER" }
end

-- A card chains (prefix-attaches, like a modifier) iff it force-draws exactly
-- one replacement card and isn't a trigger -- OR carries chain=true (the
-- DIVIDE_* spells: their bodies invoke deck[1] directly instead of calling
-- draw_actions(), so the effect is a modifier-style prefix, but with NO
-- forced draw -- on an empty deck a divide does nothing and never wraps).
local function chains(m)
	return (m.draws == 1 and m.payload == nil and m.type ~= "DRAW_MANY")
		or m.chain == true
end

local function is_multicast(m)
	return m.draws ~= nil and (m.draws >= 2 or m.draws == -1)
end

-- The ADD_TRIGGER family's forward scan (gun_actions.lua): it steps over these
-- types, counting and ultimately consuming them, until it reaches a card that
-- is none of them. An unknown (e.g. modded) card falls back to type "OTHER" and
-- is therefore stepped over, which matches the engine whenever the real type is
-- one of these four and is the conservative guess otherwise.
local SCAN_STEP_OVER = {
	MODIFIER = true, PASSIVE = true, OTHER = true, DRAW_MANY = true,
}

-- ...and the types the body accepts as a trigger target, which are also the
-- types it looks for in the remaining deck before deciding to spawn a trigger
-- at all (its `valid` check).
local SCAN_TARGET = {
	PROJECTILE = true, STATIC_PROJECTILE = true, MATERIAL = true, UTILITY = true,
}

function M.simulate(tokens, meta, opts)
	opts = opts or {}
	local spc = opts.spells_per_cast
	if spc ~= nil and spc < 1 then spc = 1 end
	local uses = opts.uses or {} -- slot -> uses_remaining; absent slot = fires

	local deck, discard, hand = {}, {}, {}
	for i, id in ipairs(tokens) do deck[#deck + 1] = { i = i, id = id } end

	local wrap_count = 0
	local wrapped_now = false -- this cast has wrapped; later draws are wrapped-in

	-- One draw off the deck, modelling draw_actions' retry loop (see the header).
	-- Forced draws (from a card's own draw_actions / trigger payload) wrap the
	-- discard pile back in when the deck is empty -- but ONLY on the first
	-- attempt: once a depleted card has sent us round again we are inside the
	-- engine's `while #deck > 0` retry, which can never reload, so an empty
	-- deck there loses the draw outright and the wand does not wrap for it.
	local function draw(forced)
		local first_attempt = true
		while true do
			if #deck == 0 then
				if first_attempt and forced and #discard > 0 then
					table.sort(discard, function(a, b) return a.i < b.i end)
					deck, discard = discard, {}
					wrap_count = wrap_count + 1
					wrapped_now = true
				else
					return nil
				end
			end
			local card = table.remove(deck, 1)
			-- .w is stamped at POP time, so a depleted card popped after a wrap
			-- is marked wrapped-in exactly like a firing one: it is in the hand,
			-- so it is inside the cast's wrapped-in span.
			if wrapped_now then card.w = true end
			hand[#hand + 1] = card -- lands in the discard at cast end either way
			if M.card_fires(uses[card.i]) then return card end
			-- Depleted: consumed, never played, never note()d into a node span.
			card.spent = true
			first_attempt = false
		end
	end

	local parse_seq -- forward declaration

	local function parse_expr(forced)
		local wraps_before = wrap_count
		local mods, first, last = {}, nil, nil
		local wfirst, wlast = nil, nil -- span of wrapped-in cards (post-wrap)
		local ffirst, flast = nil, nil -- span of the cards drawn BEFORE the wrap
		local function note(c)
			if first == nil or c.i < first then first = c.i end
			if last == nil or c.i > last then last = c.i end
			if c.w then
				if wfirst == nil or c.i < wfirst then wfirst = c.i end
				if wlast == nil or c.i > wlast then wlast = c.i end
			else
				if ffirst == nil or c.i < ffirst then ffirst = c.i end
				if flast == nil or c.i > flast then flast = c.i end
			end
		end
		local card = draw(forced)
		if card == nil then return nil end
		local m = meta_for(meta, card.id)

		while chains(m) do
			mods[#mods + 1] = card.id
			note(card)
			-- chain=true (divide) reads the deck directly: empty deck = no-op,
			-- so its follow-up draw is NOT forced and cannot wrap.
			card = draw(m.chain ~= true)
			if card == nil then
				return { kind = "leaf", id = mods[#mods], atype = "MODIFIER",
					modifiers = mods, dangling = true, first = first, last = last,
					wfirst = wfirst, wlast = wlast, ffirst = ffirst, flast = flast,
					wrap = (wrap_count > wraps_before) or nil }
			end
			m = meta_for(meta, card.id)
		end

		note(card)
		local node = { id = card.id, atype = m.type, modifiers = mods, head = card.i }

		if m.scan then
			-- Add Trigger / Add Timer / Add Death Trigger. NOT a trigger head
			-- whose payload is the next card (which is what meta payload=1 used
			-- to say, and why "ADD_TRIGGER, SPARK, BOMB" mis-grouped as
			-- "(ADD_TRIGGER SPARK) BOMB"): the head is the projectile the scan
			-- lands on, and the Add Trigger card plus everything stepped over
			-- become its modifier prefix, because the engine consumes them all.
			local n = 1
			while deck[n] ~= nil and SCAN_STEP_OVER[meta_for(meta, deck[n].id).type] do
				n = n + 1
			end
			local target = deck[n]
			local tm = (target ~= nil) and meta_for(meta, target.id) or nil
			if tm ~= nil and tm.rp ~= nil then
				mods[#mods + 1] = card.id -- the Add Trigger card itself
				-- Direct removal, not draw(): the scan only ever touches cards
				-- already in the deck, so it cannot reload and cannot wrap.
				for _ = 1, n do
					local c = table.remove(deck, 1)
					if wrapped_now then c.w = true end
					hand[#hand + 1] = c
					note(c)
					if c ~= target then mods[#mods + 1] = c.id end
				end
				local valid = false
				for _, c in ipairs(deck) do
					if SCAN_TARGET[meta_for(meta, c.id).type] then
						valid = true
						break
					end
				end
				node.id, node.atype, node.head = target.id, tm.type, target.i
				if valid then
					node.kind = "trigger"
					node.trigger = m.trigger
					node.payload = tm.rp
					node.children = parse_seq(tm.rp, true)
				else
					-- Nothing left to trigger: the body casts the consumed card
					-- plainly. It still fired, and it was still consumed.
					node.kind = "leaf"
				end
			else
				-- Scan ran off the deck, or landed on a card that cannot carry a
				-- trigger: the body consumes nothing and does nothing.
				node.kind = "leaf"
			end
		elseif is_multicast(m) then
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
				if ch.ffirst and (ffirst == nil or ch.ffirst < ffirst) then ffirst = ch.ffirst end
				if ch.flast and (flast == nil or ch.flast > flast) then flast = ch.flast end
			end
		end
		node.first, node.last = first, last
		node.wfirst, node.wlast = wfirst, wlast
		node.ffirst, node.flast = ffirst, flast
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
		-- The CAST's own slot span, straight off the hand (every card this cast
		-- drew, tagged .w at draw time if it came after a wrap). Taken here
		-- rather than folded out of the node spans because a node's first/last
		-- reach back into the wrapped-in segment, which would smear a wrapping
		-- cast's forward span across the whole wand. Same forward/wrapped split
		-- as a node: first/last forward, wfirst/wlast for the wrapped-in run.
		local cast = { nodes = nodes, wrapped = wrapped }
		if opts.trace then
			-- Every card this cast took out of the deck, by slot: the hand holds
			-- normal draws, depleted cards retried past, AND the Add Trigger
			-- scan's direct removals -- exactly the engine's notion of what a
			-- cast consumes (harness `cast.drawn`).
			local slots = {}
			for _, cd in ipairs(hand) do slots[#slots + 1] = cd.i end
			table.sort(slots)
			cast.slots = slots
		end
		-- Depleted cards this cast popped: consumed, but in no node. Reported so
		-- a renderer can say why a cast holds slots nothing was built from --
		-- including the degenerate cast whose every draw hit one, which has
		-- nodes = {} and is still a real cast that emptied part of the deck.
		local spent = {}
		for _, cd in ipairs(hand) do
			if cd.spent then spent[#spent + 1] = cd.i end
		end
		if #spent > 0 then
			table.sort(spent)
			cast.spent = spent
		end
		for _, cd in ipairs(hand) do
			if cd.w then
				if cast.wfirst == nil or cd.i < cast.wfirst then cast.wfirst = cd.i end
				if cast.wlast == nil or cd.i > cast.wlast then cast.wlast = cd.i end
			else
				if cast.first == nil or cd.i < cast.first then cast.first = cd.i end
				if cast.last == nil or cd.i > cast.last then cast.last = cd.i end
			end
		end
		-- Per-cast mana (5): every card the cast DREW is charged as it is
		-- drawn, so the hand is exactly the set that costs mana. A nil cost is
		-- 10 (ACTION_MANA_DRAIN_DEFAULT) and a NEGATIVE cost (Add Mana, Blood
		-- Magic) counts as negative -- those cards credit the pool. Always-cast
		-- cards never enter `tokens` (gun.lua plays them directly, without
		-- draw_action), so they are excluded here for free, which is right:
		-- they are never charged. This is the cast's COST only -- the pool and
		-- the not-enough-mana discards are E2 and deliberately not modeled.
		local mana = 0
		for _, cd in ipairs(hand) do
			mana = mana + (meta_for(meta, cd.id).mana or MANA_DEFAULT)
		end
		cast.mana = mana
		casts[#casts + 1] = cast
		for _, cd in ipairs(hand) do discard[#discard + 1] = cd end
		hand = {}
		if wrapped then
			-- start_reload: the recharge cycle ends after a wrapping cast.
			-- (No card is left unfired: a wrap requires an EMPTY deck, so
			-- everything fired before it; the remaining deck here is the
			-- returned discard the wrapped cast didn't re-draw.)
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
