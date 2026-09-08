--- The two prototypes this mod defines. Both exist only to power the scratch
--- surface that `/forge-circuit` builds on, and neither can be obtained,
--- selected or seen in a game.
---
--- Why they exist at all: combinators have no energy buffer and draw from a
--- network every tick, so a circuit on no network computes nothing, and
--- nothing can hand an entity energy directly. Powering it with the game's own
--- poles would mean threading a grid of them between the blueprint's entities,
--- which fails exactly when the blueprint is dense -- the case worth recording.
---
--- Written out rather than copied from an existing pole, so that nothing here
--- depends on what the player's mods happen to provide or on what those
--- prototypes happen to answer for.
---
--- The important part is the collision mask with no layers. It makes the pole
--- collide with nothing at all, so it can stand on the same tile as a
--- combinator, and its supply area covers everything regardless of how tightly
--- the blueprint is packed. With an empty sprite it is invisible as well, so
--- it neither takes space nor shows up in what is being looked at.

local constants = require("constants")

local empty_sprite = {
    filename = "__core__/graphics/empty.png",
    priority = "extra-high",
    width = 1,
    height = 1,
}

local invisible_pole_picture = {
    filename = "__core__/graphics/empty.png",
    priority = "extra-high",
    width = 1,
    height = 1,
    direction_count = 1,
}

-- Off the grid so a placement is never nudged; off the map and out of
-- blueprints so nothing of this leaks into what the player builds or copies.
local flags = {
    "placeable-off-grid",
    "not-on-map",
    "not-blueprintable",
    "not-deconstructable",
}

data:extend({
    {
        type = "electric-pole",
        name = constants.pole,
        icon = "__core__/graphics/empty.png",
        icon_size = 64,
        flags = flags,
        hidden = true,
        hidden_in_factoriopedia = true,
        selectable_in_game = false,
        max_health = 1,
        collision_box = { { -0.05, -0.05 }, { 0.05, 0.05 } },
        collision_mask = { layers = {} },
        selection_box = { { 0, 0 }, { 0, 0 } },
        supply_area_distance = constants.pole_supply,
        maximum_wire_distance = constants.pole_wire,
        draw_copper_wires = false,
        draw_circuit_wires = false,
        pictures = invisible_pole_picture,
        connection_points = { { wire = {}, shadow = {} } },
    },
    {
        type = "electric-energy-interface",
        name = constants.source,
        icon = "__core__/graphics/empty.png",
        icon_size = 64,
        flags = flags,
        hidden = true,
        hidden_in_factoriopedia = true,
        selectable_in_game = false,
        max_health = 1,
        collision_box = { { -0.05, -0.05 }, { 0.05, 0.05 } },
        collision_mask = { layers = {} },
        selection_box = { { 0, 0 }, { 0, 0 } },
        energy_source = {
            type = "electric",
            buffer_capacity = "1000GJ",
            usage_priority = "tertiary",
        },
        energy_production = "1000GW",
        energy_usage = "0kW",
        picture = empty_sprite,
    },
})

-- The tool that turns "show me your city block" into dragging a box over it.
--
-- Selection mode is the game's own blueprint mode, so the highlight while
-- dragging shows what will be captured. The area is what matters, though: the
-- export asks the game to build a blueprint of the rectangle, exactly as the
-- command does, rather than assembling one from the selected entities.
data:extend({
    {
        type = "selection-tool",
        name = constants.selector,
        icon = "__base__/graphics/icons/blueprint.png",
        icon_size = 64,
        flags = { "not-stackable", "spawnable", "only-in-cursor" },
        hidden = true,
        subgroup = "other",
        order = "z[forge]-a[region]",
        stack_size = 1,
        draw_label_for_cursor_render = true,
        -- Deliberately not the blueprint's own blue: while dragging, the
        -- border is the only thing saying which tool is in hand, and mistaking
        -- this for a blueprint selection would be easy. Amber for a plain
        -- drag, paler for the alt drag that leaves the tiles behind.
        select = {
            border_color = { 255, 170, 40 },
            mode = { "blueprint" },
            cursor_box_type = "copy",
        },
        alt_select = {
            border_color = { 255, 215, 140 },
            mode = { "blueprint" },
            cursor_box_type = "copy",
        },
    },
    {
        type = "shortcut",
        name = constants.selector_shortcut,
        order = "z[forge]",
        action = "spawn-item",
        item_to_spawn = constants.selector,
        icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x56.png",
        icon_size = 56,
        small_icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x24.png",
        small_icon_size = 24,
    },
})
