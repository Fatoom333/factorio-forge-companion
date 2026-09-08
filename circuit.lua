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

-- Every circuit connector the engine knows of, taken from its own list rather
-- than written out here. Combinators keep input and output on separate
-- connectors while everything else has one pair, and a modded entity -- or a
-- future version of the game -- can use connectors this file never heard of.
-- The engine's enum is the only complete answer, so it is the one used.
--
-- Copper connectors carry power rather than signals and are left out by the
-- colour test.
local CONNECTORS = (function()
    local out = {}
    for name, id in pairs(defines.wire_connector_id) do
        if string.find(name, "red", 1, true) or string.find(name, "green", 1, true) then
            out[#out + 1] = { id = id, label = (string.gsub(name, "_", "-")) }
        end
    end
    return out
end)()

--- Every signal on one network, as a plain name to count mapping.
local function read_network(network)
    local signals = {}
    for _, entry in pairs(network.signals or {}) do
        -- Quality makes two signals of one name distinct, so it is kept.
        local key = entry.signal.name
        if entry.signal.quality and entry.signal.quality ~= "normal" then
            key = key .. "/" .. entry.signal.quality
        end
        signals[key] = entry.count
    end
    return signals
end

--- How an entity is named in the recording: where it is, and what it is.
---
--- One decimal, not an integer: an entity with an odd footprint sits on a half
--- tile, and rounding two neighbours to the same whole number would silently
--- merge them into one.
local function key_of(entity)
    return string.format("%.1f,%.1f %s", entity.position.x, entity.position.y, entity.name)
end

--- Which connector of which entity sits on which network.
---
--- Recorded once, because it does not change while a run lasts. Signals live
--- in a network rather than in an entity -- a wire is shared -- so recording
--- them per entity per connector wrote the same values several times over. The
--- wiring is the part that is per entity, and it is written down here; the
--- frames then carry only the networks.
local function wiring(entities)
    local out = {}
    for _, entity in pairs(entities) do
        if entity.valid then
            local connectors, any = {}, false
            for _, connector in pairs(CONNECTORS) do
                local ok, network = pcall(entity.get_circuit_network, connector.id)
                if ok and network then
                    connectors[connector.label] = network.network_id
                    any = true
                end
            end
            if any then
                out[key_of(entity)] = connectors
            end
        end
    end
    return out
end

--- One sample: every network the run touches, once each.
local function sample(entities)
    local frame = {}
    for _, entity in pairs(entities) do
        if entity.valid then
            for _, connector in pairs(CONNECTORS) do
                local ok, network = pcall(entity.get_circuit_network, connector.id)
                if ok and network then
                    local id = tostring(network.network_id)
                    if frame[id] == nil then
                        frame[id] = read_network(network)
                    end
                end
            end
        end
    end
    return frame
end

--- What the game itself says about each entity.
---
--- A recording full of empty frames has several possible causes -- no power,
--- no wires, an entity that cannot operate at all -- and an empty recording
--- cannot tell them apart. `status` is the game's own answer, by name, so the
--- reason lands in the file instead of being guessed at from outside.
local function diagnose(entities)
    local out = {}
    for _, entity in pairs(entities) do
        if entity.valid then
            -- Guarded like every other prototype read: these entities come
            -- from the player's blueprint, so what they answer for is not
            -- ours to assume, and 2.0 raises rather than returning nil.
            local ok, source = pcall(function()
                return entity.prototype.electric_energy_source_prototype
            end)
            source = ok and source or nil
            out[#out + 1] = {
                name = entity.name,
                position = { x = entity.position.x, y = entity.position.y },
                status = scratch.status_name(entity),
                has_electric_source = source ~= nil,
                buffer_capacity = source and (scratch.number_key(source, "buffer_capacity") or 0) or 0,
                energy = scratch.number_key(entity, "energy") or 0,
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
        wiring = wiring(entities),
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
        networks = sample(run.entities),
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
        wiring = run.wiring,
        -- Taken now rather than at the start. An entity built this tick has
        -- not been through an electric network update yet and reports
        -- `no_power` however well powered it is about to be, which is a
        -- reading that misleads rather than informs.
        diagnostics = diagnose(run.entities),
        note = "One frame per tick, each holding every circuit network by id. "
            .. "`wiring` says which connector of which entity is on which "
            .. "network; signals live in the network, not in the entity. "
            .. "Combinators take a tick to act, so a frame shows the state "
            .. "after that tick has been simulated.",
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
