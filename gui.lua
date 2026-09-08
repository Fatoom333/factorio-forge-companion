--- A window, because four console commands with their own argument orders is a
--- poor way to reach something used often.
---
--- The window does not replace the commands: those remain the form a script
--- calls, and the only form that works when the area is known but not on
--- screen. It replaces the typing.
---
--- The important decision here is where a blueprint comes from. Asking the
--- player to paste a string into a text field would be asking them to paste
--- twenty thousand characters, which nobody will do twice. The blueprint in
--- the cursor is the one being looked at anyway, so the window reads that: put
--- a blueprint in hand, press the button, and the answer is about the thing in
--- hand.

local constants = require("constants")
local mod_gui = require("mod-gui")

local M = {}

local NAME = "forge-window"
local BUTTON = "forge-button"

--- Filled in by control.lua, which owns the actions themselves.
M.actions = {}

--- The button that opens the window, in the row mods share at the top left.
---
--- That row rather than the shortcut toolbar: the toolbar is for things taken
--- into the hand, and the region selector belongs there for exactly that
--- reason. A window is not taken into the hand.
function M.ensure_button(player)
    local flow = mod_gui.get_button_flow(player)
    if flow[BUTTON] then
        return
    end
    flow.add({
        type = "sprite-button",
        name = BUTTON,
        sprite = "item/blueprint",
        tooltip = { "forge.window-title" },
        style = mod_gui.button_style,
    })
end

--- The blueprint the player is holding, as a string, or nil.
---
--- Two places to look, not one. A blueprint taken out of the inventory is an
--- item in the cursor; one taken out of the library is a record, which lives
--- in `cursor_record` and is not an item at all. Checking only the stack made
--- the window insist there was nothing in hand while a blueprint was plainly
--- being held -- the library is where most blueprints are kept.
--- Rebuild a library record as a blueprint string.
---
--- The record knows its own contents, and a fresh blueprint made from them
--- exports like any other. Slower and longer than asking the record to export
--- itself, which is why it is the second choice rather than the first.
local function rebuild(record)
    local inventory = game.create_inventory(1)
    inventory[1].set_stack({ name = "blueprint" })

    local ok = pcall(function()
        inventory[1].set_blueprint_entities(record.get_blueprint_entities())
        local tiles = record.get_blueprint_tiles()
        if tiles then
            inventory[1].set_blueprint_tiles(tiles)
        end
        -- Carried across so the copy is the same blueprint, not merely the
        -- same entities: a city block without its grid snapping is a
        -- different thing.
        inventory[1].label = record.label
        inventory[1].blueprint_snap_to_grid = record.blueprint_snap_to_grid
        inventory[1].blueprint_absolute_snapping = record.blueprint_absolute_snapping
        inventory[1].blueprint_position_relative_to_grid =
            record.blueprint_position_relative_to_grid
    end)

    local text = ok and inventory[1].export_stack() or nil
    inventory.destroy()
    if text == "" then
        return nil
    end
    return text
end

function M.blueprint_in_hand(player)
    local record = player.cursor_record
    if record ~= nil and record.valid and record.type == "blueprint" then
        local ok, text = pcall(function()
            return record.export_stack()
        end)
        if ok and text ~= nil and text ~= "" then
            return text
        end
        return rebuild(record)
    end

    local stack = player.cursor_stack
    if stack == nil or not stack.valid_for_read then
        return nil
    end
    if not stack.is_blueprint or not stack.is_blueprint_setup() then
        return nil
    end
    return stack.export_stack()
end

--- Find an element by name anywhere below this one.
---
--- Addressing children by position is what broke the first version: the button
--- for a circuit run lives inside a row, not directly in the body, so looking
--- for it there found nothing. Names are stable, positions are not.
local function find(element, name)
    if element == nil or not element.valid then
        return nil
    end
    if element[name] then
        return element[name]
    end
    for _, child in pairs(element.children) do
        local found = find(child, name)
        if found then
            return found
        end
    end
    return nil
end

--- Where the window lives: the left-hand flow mods share, under their buttons.
---
--- Not the screen. A window floating in the middle is something to move out of
--- the way before playing; one in the corner sits where every other mod's does
--- and needs nothing done to it.
local function container(player)
    return mod_gui.get_frame_flow(player)
end

local function status(player, message)
    local label = find(container(player)[NAME], "status")
    if label then
        label.caption = message
    end
end

function M.close(player)
    local window = container(player)[NAME]
    if window then
        window.destroy()
    end
end

function M.open(player)
    M.close(player)

    local window = container(player).add({
        type = "frame",
        name = NAME,
        direction = "vertical",
    })

    local title = window.add({ type = "flow", direction = "horizontal" })
    title.style.horizontally_stretchable = true
    title.add({ type = "label", caption = { "forge.window-title" }, style = "frame_title" })
    local filler = title.add({ type = "empty-widget" })
    filler.style.horizontally_stretchable = true
    filler.style.height = 24
    title.add({
        type = "sprite-button",
        name = "forge-close",
        sprite = "utility/close",
        style = "frame_action_button",
    })

    local body = window.add({ type = "frame", style = "inside_shallow_frame_with_padding",
                              direction = "vertical" })

    body.add({ type = "label", caption = { "forge.window-save" }, style = "caption_label" })
    body.add({ type = "button", name = "forge-do-export", caption = { "forge.window-export" } })
    body.add({ type = "button", name = "forge-do-selector", caption = { "forge.window-selector" } })

    body.add({ type = "line" })
    body.add({ type = "label", caption = { "forge.window-held" }, style = "caption_label" })
    body.add({ type = "label", name = "forge-held", caption = { "forge.window-nothing-held" } })
    body.add({ type = "button", name = "forge-do-verify", caption = { "forge.window-verify" } })

    local run = body.add({ type = "flow", direction = "horizontal" })
    run.add({ type = "button", name = "forge-do-circuit", caption = { "forge.window-circuit" } })
    local ticks = run.add({
        type = "textfield",
        name = "forge-ticks",
        text = tostring(constants.confirm_above_ticks),
        numeric = true,
        allow_decimal = false,
        allow_negative = false,
    })
    ticks.style.width = 80

    body.add({ type = "line" })
    body.add({ type = "button", name = "forge-do-clean", caption = { "forge.window-clean" } })

    window.add({ type = "label", name = "status", caption = { "forge.window-ready" } })
    M.refresh(player)
    return window
end

--- What the game says is in the cursor, in words.
---
--- Shown instead of a flat "nothing in hand" because that sentence was wrong
--- twice while a blueprint was plainly being held, and gave nothing to work
--- from. A window that cannot see something should at least say what it does
--- see.
local function describe_cursor(player)
    local parts = {}

    local stack = player.cursor_stack
    if stack == nil then
        parts[#parts + 1] = "no stack"
    elseif not stack.valid_for_read then
        parts[#parts + 1] = "empty stack"
    else
        parts[#parts + 1] = "stack " .. stack.name
    end

    local ok, record = pcall(function()
        return player.cursor_record
    end)
    if not ok then
        parts[#parts + 1] = "no cursor_record in this version"
    elseif record == nil then
        parts[#parts + 1] = "no record"
    else
        local readable, kind = pcall(function()
            return record.type
        end)
        parts[#parts + 1] = "record " .. (readable and tostring(kind) or "unreadable")
    end

    return table.concat(parts, ", ")
end

--- Keep the window honest about what is in the cursor.
function M.refresh(player)
    local window = container(player)[NAME]
    if window == nil then
        return
    end
    local held = M.blueprint_in_hand(player) ~= nil
    local label = find(window, "forge-held")
    if label then
        label.caption = held and { "forge.window-blueprint-held" }
            or { "forge.window-nothing-held-detail", describe_cursor(player) }
    end
    for _, name in pairs({ "forge-do-verify", "forge-do-circuit" }) do
        local button = find(window, name)
        if button then
            button.enabled = held
        end
    end
end

function M.toggle(player)
    if container(player)[NAME] then
        M.close(player)
    else
        M.open(player)
    end
end

--- Every button, in one place, so the wiring can be read at a glance.
function M.on_click(event)
    local player = game.get_player(event.player_index)
    local name = event.element.name

    -- Refreshed on every click as well as on the cursor event, since a record
    -- picked from the library does not always announce itself the way an item
    -- does.
    M.refresh(player)

    if name == BUTTON then
        M.toggle(player)
    elseif name == "forge-close" then
        M.close(player)
    elseif name == "forge-do-export" then
        M.actions.export(player)
        status(player, { "forge.window-done" })
    elseif name == "forge-do-selector" then
        M.actions.selector(player)
        status(player, { "forge.window-took-selector" })
    elseif name == "forge-do-clean" then
        M.actions.clean(player)
        status(player, { "forge.window-done" })
    elseif name == "forge-do-verify" or name == "forge-do-circuit" then
        local text = M.blueprint_in_hand(player)
        if text == nil then
            status(player, { "forge.window-nothing-held" })
            return
        end
        if name == "forge-do-verify" then
            M.actions.verify(player, text)
        else
            local field = find(container(player)[NAME], "forge-ticks")
            local ticks = tonumber(field and field.text or "") or 0
            if ticks < 1 then
                status(player, { "forge.window-ticks-needed" })
                return
            end
            M.actions.circuit(player, text, ticks)
        end
        status(player, { "forge.window-done" })
    end
end

return M
