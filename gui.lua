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
function M.blueprint_in_hand(player)
    local stack = player.cursor_stack
    if stack == nil or not stack.valid_for_read then
        return nil
    end
    if not stack.is_blueprint or not stack.is_blueprint_setup() then
        return nil
    end
    return stack.export_stack()
end

local function status(player, message)
    local window = player.gui.screen[NAME]
    if window and window.status then
        window.status.caption = message
    end
end

function M.close(player)
    local window = player.gui.screen[NAME]
    if window then
        window.destroy()
    end
end

function M.open(player)
    M.close(player)

    local window = player.gui.screen.add({
        type = "frame",
        name = NAME,
        direction = "vertical",
    })
    window.auto_center = true

    local title = window.add({ type = "flow", direction = "horizontal" })
    title.drag_target = window
    title.add({ type = "label", caption = { "forge.window-title" }, style = "frame_title" })
    local filler = title.add({ type = "empty-widget", style = "draggable_space_header" })
    filler.style.horizontally_stretchable = true
    filler.style.height = 24
    filler.drag_target = window
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

--- Keep the window honest about what is in the cursor.
function M.refresh(player)
    local window = player.gui.screen[NAME]
    if window == nil then
        return
    end
    local held = M.blueprint_in_hand(player) ~= nil
    local label = window.children[2]["forge-held"]
    label.caption = held and { "forge.window-blueprint-held" } or { "forge.window-nothing-held" }
    window.children[2]["forge-do-verify"].enabled = held
    window.children[2]["forge-do-circuit"].enabled = held
end

function M.toggle(player)
    if player.gui.screen[NAME] then
        M.close(player)
    else
        M.open(player)
    end
end

--- Every button, in one place, so the wiring can be read at a glance.
function M.on_click(event)
    local player = game.get_player(event.player_index)
    local name = event.element.name

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
            local window = player.gui.screen[NAME]
            local ticks = tonumber(window.children[2]["forge-ticks"].text) or 0
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
