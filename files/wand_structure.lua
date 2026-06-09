-- Pure deck -> structure-tree parser. No game APIs; unit-testable.
--
-- Mirrors how data/scripts/gun/gun.lua resolves a shot: cards are consumed
-- from one ordered stream; DRAW_MANY multicasts gather the next `group` cards,
-- trigger projectiles open a nested sub-shot of `payload` cards, and modifiers
-- prefix-attach to the projectile they precede. The result is a Lisp-like tree.
--
-- Input : tokens = ordered array of action_id strings (a wand's cards)
--         meta   = the table from files/structure_meta.lua
-- Output: array of nodes. Node shapes:
--   leaf      { kind="leaf",      id, atype, modifiers={...} }
--   multicast { kind="multicast", id, atype="DRAW_MANY", group=N, children={...}, modifiers={...} }
--   trigger   { kind="trigger",   id, atype, trigger=kind, payload=N, children={...}, modifiers={...} }
-- A trailing run of modifiers with no projectile becomes a leaf with dangling=true.

local M = {}

local function meta_for(meta, id)
	return meta[id] or { type = "OTHER" }
end

function M.build(tokens, meta)
	local i, n = 1, #tokens
	local parse_seq -- forward declaration

	local function parse_expr()
		local mods = {}
		while i <= n do
			local m = meta_for(meta, tokens[i])
			if m.type == "MODIFIER" or m.type == "PASSIVE" then
				mods[#mods + 1] = tokens[i]
				i = i + 1
			else
				break
			end
		end

		if i > n then
			if #mods > 0 then
				return { kind = "leaf", id = mods[#mods], atype = "MODIFIER", modifiers = mods, dangling = true }
			end
			return nil
		end

		local id = tokens[i]; i = i + 1
		local m = meta_for(meta, id)
		local node = { id = id, atype = m.type, modifiers = mods }

		if m.type == "DRAW_MANY" and m.group then
			node.kind = "multicast"
			node.group = m.group
			node.children = parse_seq(m.group)
		elseif m.payload then
			node.kind = "trigger"
			node.trigger = m.trigger
			node.payload = m.payload
			node.children = parse_seq(m.payload)
		else
			node.kind = "leaf"
		end
		return node
	end

	parse_seq = function(limit)
		local out = {}
		while i <= n and (limit == nil or #out < limit) do
			local node = parse_expr()
			if node == nil then break end
			out[#out + 1] = node
		end
		return out
	end

	return parse_seq(nil)
end

return M
