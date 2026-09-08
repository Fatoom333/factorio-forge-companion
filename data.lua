--- The two prototypes the mod defines, both of them tools for the scratch
--- surface and neither of them obtainable in a game.
---
--- `/forge-circuit` has to power what it builds: combinators have no energy
--- buffer and draw from a network every tick, so one that is on no network
--- computes nothing at all. Doing that with the game's own poles means a grid
--- of them threaded between the blueprint's entities, which fails exactly when
--- the blueprint is dense -- the case worth recording.
---
--- One pole with the largest supply area the engine allows covers 128 by 128
--- tiles by itself, so in practice it is placed once, in whatever corner is
--- free, and reaches everything. That is the whole reason for defining
--- anything: a testing tool, not something the game world gains.
---
--- Both are copies of existing prototypes, so they inherit working graphics
--- and sounds without this file having to describe any. Neither has an item,
--- so neither can be built, mined or held by a player.

local function first_of(kind)
    for _, prototype in pairs(data.raw[kind] or {}) do
        return prototype
    end
    return nil
end

local pole_template = first_of("electric-pole")
if pole_template then
    local pole = table.deepcopy(pole_template)
    pole.name = "forge-power-pole"
    pole.minable = nil
    pole.placeable_by = nil
    pole.next_upgrade = nil
    pole.fast_replaceable_group = nil
    pole.hidden = true
    pole.hidden_in_factoriopedia = true
    -- 64 is the largest supply area the engine accepts; the wire reach only
    -- has to let two of them meet when a blueprint is wider than one covers.
    pole.supply_area_distance = 64
    pole.maximum_wire_distance = 64
    data:extend({ pole })
end

local source_template = first_of("electric-energy-interface")
if source_template then
    local source = table.deepcopy(source_template)
    source.name = "forge-power-source"
    source.minable = nil
    source.placeable_by = nil
    source.hidden = true
    source.hidden_in_factoriopedia = true
    source.energy_production = "1000GW"
    source.energy_usage = "0kW"
    source.energy_source = {
        type = "electric",
        buffer_capacity = "1000GJ",
        usage_priority = "tertiary",
    }
    data:extend({ source })
end
