--- The surface that `/forge-verify` and `/forge-circuit` build on.
---
--- A blueprint pasted onto chunks that have never been generated places
--- nothing at all, and says nothing about it: there is simply no ground to
--- build on, and the call returns an empty list. That is exactly how the first
--- version reported "0 placed" for a blueprint the player could paste by hand
--- without trouble. So generating the ground first is not a refinement here,
--- it is the difference between working and not.

local constants = require("constants")

local M = {}

local NAME = "forge-scratch"
local CHUNK = 32

--- The scratch surface, created on first use.
---
--- Lab tiles because they are flat, buildable and free of decoration; day
--- frozen because a circuit run must not be measuring the time of day.
function M.surface()
    local surface = game.surfaces[NAME]
    if not surface then
        surface = game.create_surface(NAME, { width = 2000, height = 2000 })
        surface.generate_with_lab_tiles = true
        surface.always_day = true
        surface.freeze_daytime = true
    end
    return surface
end

--- What the game says an entity is doing, by name rather than by number.
function M.status_name(entity)
    local status = entity.status
    if status == nil then
        return "no status"
    end
    for name, value in pairs(defines.entity_status) do
        if value == status then
            return name
        end
    end
    return tostring(status)
end

--- Empty it, so one run cannot see what the previous run left behind.
function M.clear(surface)
    for _, entity in pairs(surface.find_entities()) do
        entity.destroy()
    end
end

--- Delete the surface outright, chunks and all.
---
--- Clearing the entities is not enough. The ground stays in the save for good
--- once generated, and grows with the largest blueprint ever checked, so a mod
--- that promises to touch nothing in your world has to take it back out again.
---
--- Refuses while somebody is standing on it, since deleting the ground under a
--- player is a surprise nobody asked for.
---
---@return string "removed", "absent" or "occupied"
function M.remove()
    local surface = game.surfaces[NAME]
    if not surface then
        return "absent"
    end
    for _, player in pairs(game.players) do
        if player.surface == surface then
            return "occupied"
        end
    end
    game.delete_surface(surface)
    return "removed"
end

--- Generate the ground the blueprint is about to be built on.
---
---@param surface LuaSurface
---@param entities table|nil blueprint entities, in blueprint coordinates
---@param origin table where the blueprint will be pasted
---@return table the area the blueprint will occupy, in surface coordinates
function M.prepare(surface, entities, origin)
    local reach = 0
    for _, entry in pairs(entities or {}) do
        local position = entry.position or { x = 0, y = 0 }
        reach = math.max(reach, math.abs(position.x), math.abs(position.y))
    end

    -- A square of chunks around the paste point, wide enough for the whole
    -- blueprint and one chunk of slack, since an entity can reach past the
    -- position it is recorded at.
    surface.request_to_generate_chunks(origin, math.ceil(reach / CHUNK) + 1)
    surface.force_generate_chunk_requests()

    return {
        min_x = origin.x - reach,
        min_y = origin.y - reach,
        max_x = origin.x + reach,
        max_y = origin.y + reach,
    }
end

--- Read a number from a prototype, or nothing if it will not answer.
---
--- A prototype in 2.0 raises on a key that does not belong to it rather than
--- returning nil, and the type is not a reliable guide to what it will answer
--- for: a mod can register something as an electric pole that does not respond
--- to `supply_area_distance` at all. Since this walks whatever prototypes the
--- player happens to have, it has to survive that rather than assume it away.
---@return number|nil
function M.number_key(prototype, key)
    local ok, value = pcall(function()
        return prototype[key]
    end)
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

--- The mod's own prototypes, defined in data.lua. Nothing else is consulted:
--- the game's poles vary in size between mods, cannot be counted on to answer
--- for their own supply area, and have to be threaded between the blueprint's
--- entities. Ours collides with nothing and is invisible, so it goes wherever
--- it is needed and covers whatever is there.
local POLE = "forge-power-pole"
local SOURCE = "forge-power-source"

--- Place one entity at a position, or as near to it as there is room.
local function place_near(surface, force, name, position, limit)
    for radius = 0, limit do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if radius == 0 or math.abs(dx) == radius or math.abs(dy) == radius then
                    local spot = { x = position.x + dx, y = position.y + dy }
                    if surface.can_place_entity({ name = name, position = spot, force = force }) then
                        return surface.create_entity({ name = name, position = spot, force = force })
                    end
                end
            end
        end
    end
    return nil
end

--- Lay a power network over an area, so that what stands there can run.
---
--- Combinators are electrical devices with no energy buffer at all: they draw
--- from the network every tick, and one that is on no network reports
--- `no_power` and computes nothing. Nothing can hand an entity energy directly
--- either, since there is no buffer to put it in. So the surface gets real
--- poles and a real source.
---
--- Called after the blueprint is built, never before, so that a pole can never
--- take a tile the blueprint wanted.
---
---@return table what was laid down, for the run's diagnostics
function M.power(surface, force, box)
    local pole = prototypes.entity[POLE]
    if pole == nil then
        return { poles = 0, note = "the mod's own pole prototype is missing" }
    end

    -- Coverage wants the poles no further apart than the area they supply;
    -- staying connected wants them within reach of each other's wires. The
    -- numbers come from constants.lua, which is also what defined the pole:
    -- asking the prototype returned nothing and collapsed the spacing to a
    -- single tile.
    local supply = constants.pole_supply
    local step = math.max(math.min(supply * 2, constants.pole_wire), 1)

    local placed, anchor = 0, nil
    local x = box.min_x
    while x <= box.max_x + step do
        local y = box.min_y
        while y <= box.max_y + step do
            local entity = place_near(surface, force, pole.name, { x = x, y = y }, 3)
            if entity then
                placed = placed + 1
                anchor = anchor or entity
            end
            y = y + step
        end
        x = x + step
    end

    local report = {
        pole = pole.name,
        supply_area = supply,
        poles = placed,
        step = step,
        source = "none",
    }
    if anchor == nil then
        report.note = "nowhere to put a pole"
        return report
    end

    if prototypes.entity[SOURCE] == nil then
        report.note = "the mod's own energy source prototype is missing"
        return report
    end

    local source = place_near(
        surface, force, SOURCE, anchor.position, math.max(math.floor(supply), 1))
    if source == nil then
        report.note = "nowhere to put the energy source"
        return report
    end

    -- The prototype declares a production, but a run whose network existed
    -- and carried nothing says that is not enough on its own, so the entity is
    -- told directly. Whether that took, and what the game makes of the source
    -- afterwards, both go into the report: a network with no power in it
    -- should say so rather than show up as a circuit that did nothing.
    local assigned = pcall(function()
        source.power_production = constants.source_production
    end)

    report.source = source.name
    report.production_assigned = assigned
    report.source_status = M.status_name(source)
    report.source_network = source.electric_network_id or "none"
    return report
end

return M
