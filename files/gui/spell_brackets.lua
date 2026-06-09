-- spell_brackets.lua

print("[TestMod] Loading spell_brackets.lua...")

-- Helper function to determine spell trigger type
function GetSpellTriggerType(action)
    if action.type == ACTION_TYPE_PROJECTILE then
        return "PROJECTILE"
    elseif action.type == ACTION_TYPE_STATIC_PROJECTILE then
        return "STATIC"
    elseif action.type == ACTION_TYPE_MODIFIER then
        return "MODIFIER"
    elseif action.type == ACTION_TYPE_DRAW_MANY then
        return "DRAW"
    elseif action.type == ACTION_TYPE_MATERIAL then
        return "MATERIAL"
    end
    return "OTHER"
end

-- Helper function to get bracket color based on trigger type
function GetBracketColor(trigger_type)
    if trigger_type == "PROJECTILE" then
        return 0.8, 0.2, 0.2 -- Red
    elseif trigger_type == "STATIC" then
        return 0.2, 0.8, 0.2 -- Green
    elseif trigger_type == "MODIFIER" then
        return 0.2, 0.2, 0.8 -- Blue
    elseif trigger_type == "DRAW" then
        return 0.8, 0.8, 0.2 -- Yellow
    elseif trigger_type == "MATERIAL" then
        return 0.8, 0.2, 0.8 -- Purple
    end
    return 0.7, 0.7, 0.7 -- Gray for unknown types
end

-- Store the original draw_action_icon function
local original_draw_action_icon = draw_action_icon or function() end  -- Fallback if function doesn't exist

-- Override the draw_action_icon function
function draw_action_icon(action, x, y, alpha)
    print("[TestMod] Drawing action icon: " .. tostring(action.id)) -- Debug print
    
    -- Get bracket style from settings
    local bracket_style = ModSettingGet("testMod.bracket_style") or "square"
    local brackets = {
        square = {"[", "]"},
        round = {"(", ")"},
        curly = {"{", "}"},
        angle = {"<", ">"}
    }
    
    -- Draw opening bracket
    GuiText(gui, x - 4, y, "[")  -- Start with square brackets for testing
    
    -- Draw the original spell icon
    original_draw_action_icon(action, x, y, alpha)
    
    -- Draw closing bracket
    GuiText(gui, x + 12, y, "]")
end

function OnWorldPostUpdate()
    if GameIsInventoryOpen() then
        -- Debug print when inventory is open
        print("[TestMod] Inventory is open")
    end
end

print("[TestMod] Finished loading spell_brackets.lua")
