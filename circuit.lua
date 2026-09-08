--- Running a circuit and recording what it does, tick by tick.
---
--- This is the part that cannot be reproduced from outside. Combinator
--- behaviour lives in the engine, not in the game's data files, so a tool
--- outside can only model it -- and a model is a guess until something checks
--- it. Here the game runs the circuit itself, which makes the result true by
--- construction rather than by argument.
---
--- The recording is per tick because that is the unit circuits are built in.
--- One tick of delay per combinator is the whole basis of counters, clocks and
--- latches, so a summary that loses tick boundaries loses the thing being
--- studied.

local scratch = require("scratch")

local M = {}

local OUTPUT = "factorio-forge/"

-- Combinators keep their input and output on separate connectors; everything
-- else has one pair. Reading all of them and keeping whichever exist avoids
-- having to know which kind of entity this is.
local CONNECTORS = {
    { id = defines.wire_connector_id.circuit_red, label = "red" },
    { id = defines.wire_connector_id.circuit_green, label = "green" },
    { id = defines.wire_connector_id.combinator_input_red, label = "input-red" },
    { id = defines.wire_connector_id.combinator_input_green, label = "input-green" },
    { id = defines.wire_connector_id.combinator_output_red, label = "output-red" },
    { id = defines.wire_connector_id.combinator_output_green, label = "output-green" },
}

--- Every signal on one network, as a plain name to count mapping.
local function read_network(network)
    if not network then
        return nil
    end
    local signals = {}
    for _, entry in pairs(network.signals or {}) do
        -- Quality makes two signals of one name distinct, so it is kept.
        local key = entry.signal.name
        if entry.signal.quality and entry.signal.quality ~= "normal" then
            key = key .. "/" .. entry.signal.quality
        end
        signals[key] = entry.count
    end
    return { id = network.network_id, signals = signals }
end

--- What the game itself says about each entity at the start of a run.
---
--- A recording full of empty frames has several possible causes -- no power,
--- no wires, an entity that cannot operate at all -- and an empty recording
--- cannot tell them apart. `status` is the game's own answer, by name, so the
--- reason lands in the file instead of being guessed at from outside.
local function diagnose(entities)
    local status_names = {}
    for name, value in pairs(defines.entity_status) do
        status_names[value] = name
    end

    local out = {}
    for _, entity in pairs(entities) do
        if entity.valid then
            local source = entity.prototype.electric_energy_source_prototype
            out[#out + 1] = {
                name = entity.name,
                position = { x = entity.position.x, y = entity.position.y },
                status = entity.status and status_names[entity.status] or "no status",
                has_electric_source = source ~= nil,
                buffer_capacity = source and source.buffer_capacity or 0,
                energy = entity.energy,
                electric_network = entity.electric_network_id or "none",
            }
        end
    end
    return out
end

--- One sample of everything wired, keyed by where it is.
local function sample(entities)
    local frame = {}
    for _, entity in pairs(entities) do
        if entity.valid then
            -- One decimal, not an integer: an entity with an odd footprint
            -- sits on a half tile, and rounding two neighbours to the same
            -- whole number would silently merge them into one recording.
            local at = string.format("%.1f,%.1f", entity.position.x, entity.position.y)
            local readings = {}
            local any = false
            for _, connector in pairs(CONNECTORS) do
                local ok, network = pcall(entity.get_circuit_network, connector.id)
                if ok and network then
                    readings[connector.label] = read_network(network)
                    any = true
                end
            end
            if any then
                frame[at .. " " .. entity.name] = readings
            end
        end
    end
    return frame
end

--- Start a run. Collection happens on the tick handler below.
---@param player LuaPlayer
---@param text string blueprint string
---@param ticks number how many ticks to record
function M.start(player, text, ticks)
    local inventory = game.create_inventory(1)
    inventory[1].import_stack(text)
    if not inventory[1].is_blueprint_setup() then
        inventory.destroy()
        player.print({ "forge.not-a-blueprint" })
        return
    end

    local surface = scratch.surface()
    scratch.clear(surface)

    -- Ungenerated chunks are ground that does not exist yet, and building on
    -- them places nothing at all.
    local origin = { x = 0, y = 0 }
    local box = scratch.prepare(surface, inventory[1].get_blueprint_entities(), origin)

    -- Built rather than ghosted: a ghost has no circuit network and nothing to
    -- read.
    local built = inventory[1].build_blueprint({
        surface = surface,
        force = player.force,
        position = origin,
        build_mode = defines.build_mode.forced,
    })
    inventory.destroy()

    local entities = {}
    for _, ghost in pairs(built) do
        if ghost.valid then
            if ghost.name == "entity-ghost" then
                local _, revived = ghost.revive()
                if revived then
                    entities[#entities + 1] = revived
                end
            else
                entities[#entities + 1] = ghost
            end
        end
    end

    if #entities == 0 then
        player.print({ "forge.circuit-nothing-built" })
        scratch.remove()
        return
    end

    -- After the blueprint, so a pole can only take a tile the blueprint did
    -- not want. Without this the combinators stand unpowered and the recording
    -- is the right number of frames of nothing happening.
    local power = scratch.power(surface, player.force, box)

    storage.run = {
        player = player.index,
        entities = entities,
        power = power,
        diagnostics = diagnose(entities),
        remaining = ticks,
        total = ticks,
        started_tick = game.tick,
        previous_speed = game.speed,
        frames = {},
    }

    -- The point of running outside the normal rhythm: a five minute timer is
    -- eighteen thousand ticks, and waiting five real minutes for it is absurd.
    game.speed = 60

    script.on_event(defines.events.on_tick, M.on_tick)
    player.print({ "forge.circuit-started", #entities, ticks })
end

function M.on_tick()
    local run = storage.run
    if not run then
        script.on_event(defines.events.on_tick, nil)
        return
    end

    run.frames[#run.frames + 1] = {
        tick = game.tick - run.started_tick,
        entities = sample(run.entities),
    }
    run.remaining = run.remaining - 1

    if run.remaining > 0 then
        return
    end

    game.speed = run.previous_speed
    script.on_event(defines.events.on_tick, nil)

    local player = game.get_player(run.player)
    local path = OUTPUT .. "circuit-run.json"
    helpers.write_file(path, helpers.table_to_json({
        exported_by = "factorio-forge-companion",
        ticks = run.total,
        entities = #run.entities,
        power = run.power,
        diagnostics = run.diagnostics,
        note = "One frame per tick. Combinators take a tick to act, so a frame "
            .. "shows the state after that tick has been simulated.",
        frames = run.frames,
    }), false)
    storage.run = nil

    -- Only now, with the recording written: the circuit had to keep running
    -- somewhere until the last tick was sampled.
    scratch.remove()

    if player then
        player.print({ "forge.circuit-done", run.total, path })
    end
end

--- Restore the tick handler after a save is loaded mid-run.
function M.on_load()
    if storage.run then
        script.on_event(defines.events.on_tick, M.on_tick)
    end
end

return M
