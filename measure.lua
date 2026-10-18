--- `/forge-measure`: build a blueprint on an empty surface, feed it, run it, and
--- write down what came out.
---
--- `/forge-verify` asks whether a blueprint places; this asks what it does. The
--- build is put on a surface of its own, so nothing of the base around it can
--- feed it or block it, and the surface is given the properties of the planet
--- the plan is for, so a recipe that needs a pressure or a gravity runs.
---
--- How the pieces are done, and why:
---
--- * Power: the mod's own invisible poles and its `electric-energy-interface`
---   (`forge-power-source`), a source of a gigawatt, so that power is never the
---   reason a machine stands still. A machine that shows `no_power` anyway has a
---   pole that did not reach it, and the file says so.
--- * Supply: items are put on the belt at the declared tile by script, onto the
---   declared lane, at the declared rate (a token counter, one item at a time as
---   room allows). That keeps the rate exact, which a chest and an inserter
---   cannot do, and shows backpressure: the rate actually fed is written next
---   to the declared one. A fluid comes from an `infinity-pipe` at the tile; its
---   rate is not limited, only noted.
--- * Sinks: at every declared output the belt is emptied each tick and what was
---   taken is counted by item. That count is the output of the build as the
---   player would see it at the end of the belt.
--- * Production and consumption: the force's own production statistics for the
---   measuring surface, as the difference between the end and the start of the
---   window. They count what machines make and use, wherever it goes.
--- * Machines: the status of every crafting machine is sampled during the
---   window; the file gives the share of samples spent working, waiting for an
---   ingredient (and which), blocked on a full output, without power, and so on.
---
--- The spec arrives as the command's text, since a mod cannot read a file; the
--- runner (`tools/headless-run.ps1 -Measure`) reads the spec file and sends it.

local constants = require("constants")
local scratch = require("scratch")

local M = {}

local OUTPUT = "factorio-forge/"
local SURFACE_PREFIX = "forge-measure"
-- Statuses are sampled this often during the window (ticks).
local SAMPLE_EVERY = 5
-- The longest warm-up or window a spec may ask for, in game seconds.
local MAX_SECONDS = 3600
-- A token counter never holds more than this many items back, so a belt that
-- was full for a while does not release a burst when it clears.
local TOKEN_CAP = 2

-- Which entities are worth asking "were you working".
local MACHINE_TYPES = {
    "assembling-machine", "furnace", "lab", "rocket-silo", "mining-drill",
}
-- What can carry a lane to feed or drain.
local BELT_TYPES = { "transport-belt", "underground-belt", "splitter", "loader", "loader-1x1", "linked-belt" }

-- The entity statuses by what they mean for a measurement.
local STATUS_GROUP = {
    working = "working",
    preparing_rocket_for_launch = "working",
    launching_rocket = "working",
    no_ingredients = "waiting_input",
    no_input_fluid = "waiting_input",
    low_input_fluid = "waiting_input",
    fluid_ingredient_shortage = "waiting_input",
    item_ingredient_shortage = "waiting_input",
    missing_required_fluid = "waiting_input",
    missing_science_packs = "waiting_input",
    waiting_for_source_items = "waiting_input",
    waiting_for_more_items = "waiting_input",
    no_minable_resources = "waiting_input",
    full_output = "output_full",
    waiting_for_space_in_destination = "output_full",
    no_power = "no_power",
    low_power = "no_power",
    not_plugged_in_electric_network = "no_power",
    recharging_after_power_outage = "no_power",
    no_fuel = "no_fuel",
}
local GROUPS = { "working", "waiting_input", "output_full", "no_power", "no_fuel", "other" }

local function say(player, message)
    if player then
        player.print(message)
    elseif rcon then
        rcon.print(message)
    end
end

local function write_result(payload)
    helpers.write_file(OUTPUT .. "measure.json", helpers.table_to_json(payload), false)
end

local function status_names()
    local names = {}
    for name, value in pairs(defines.entity_status) do
        names[value] = name
    end
    return names
end

local function key(name, x, y)
    return string.format("%s@%.2f,%.2f", name, x, y)
end

--- Properties of the surface the plan is for, from the prototypes alone.
---
--- A planet is a prototype that lists its surface properties (pressure, gravity,
--- and the rest); every property it does not list has the default the property
--- itself names. No planet is known by name here: the name in the spec is looked
--- up, and a name nobody has gives the defaults, which the file says.
---
---@return table properties, string where they came from
local function surface_properties(name)
    local values = {}
    for property_name, property in pairs(prototypes.surface_property) do
        values[property_name] = property.default_value
    end
    if not name then
        return values, "defaults (the spec names no surface)"
    end

    local proto
    for _, lookup in pairs({
        function() return prototypes.space_location[name] end,
        function() return prototypes.planet[name] end,
        function() return game.planets[name].prototype end,
    }) do
        local ok, found = pcall(lookup)
        if ok and found then
            proto = found
            break
        end
    end
    if not proto then
        return values, "defaults (no planet or space location named " .. name .. ")"
    end
    local ok, listed = pcall(function() return proto.surface_properties end)
    if ok and listed then
        for property_name, value in pairs(listed) do
            values[property_name] = value
        end
    end
    return values, "prototype " .. name
end

local function new_surface(name)
    for _, old in pairs(game.surfaces) do
        if string.sub(old.name, 1, #SURFACE_PREFIX) == SURFACE_PREFIX then
            game.delete_surface(old)
        end
    end
    local surface = game.create_surface(
        SURFACE_PREFIX .. "-" .. game.tick,
        { width = constants.scratch_size, height = constants.scratch_size })
    surface.generate_with_lab_tiles = true
    surface.always_day = true
    surface.freeze_daytime = true

    local values, where = surface_properties(name)
    local applied = {}
    for property_name, value in pairs(values) do
        -- What the surface answers afterwards is what is written down, not what was asked.
        if pcall(function() surface.set_property(property_name, value) end) then
            local ok, now = pcall(function() return surface.get_property(property_name) end)
            applied[property_name] = ok and now or value
        end
    end
    return surface, { name = name, properties = applied, from = where }
end

--- Where the game put the blueprint, found by looking rather than by rule.
---
--- The game centres a blueprint on the spot it is pasted at, by its own idea of
--- the centre. The spec speaks in the blueprint's coordinates, so the shift
--- between the two is found by trying: take the entry whose name is rarest among
--- the entities that stand, try each of them as its twin, and keep the shift
--- under which most entries find a standing entity of their name.
local function find_anchor(entries, built)
    local by_name = {}
    local standing = {}
    for _, entity in pairs(built) do
        local list = by_name[entity.name]
        if not list then
            list = {}
            by_name[entity.name] = list
        end
        list[#list + 1] = entity
        standing[key(entity.name, entity.position.x, entity.position.y)] = true
    end
    local pick, pick_count
    for _, entry in pairs(entries) do
        local list = by_name[entry.name]
        if list and (not pick_count or #list < pick_count) then
            pick, pick_count = entry, #list
        end
    end
    if not pick then
        return nil
    end
    local best
    for _, twin in pairs(by_name[pick.name]) do
        local dx = twin.position.x - pick.position.x
        local dy = twin.position.y - pick.position.y
        local score = 0
        for _, entry in pairs(entries) do
            if standing[key(entry.name, entry.position.x + dx, entry.position.y + dy)] then
                score = score + 1
            end
        end
        if not best or score > best.matched then
            best = { x = dx, y = dy, matched = score }
            if score == #entries then
                break
            end
        end
    end
    return best
end

local function tile_centre(anchor, at)
    return { x = at[1] + 0.5 + anchor.x, y = at[2] + 0.5 + anchor.y }
end

local function belt_at(surface, anchor, at)
    local found = surface.find_entities_filtered({
        position = tile_centre(anchor, at), type = BELT_TYPES, limit = 1 })
    return found[1]
end

--- The fastest belt among the build's own, for a belt the measuring has to add.
local function belt_name(built)
    local best, best_speed = nil, -1
    for _, entity in pairs(built) do
        if entity.type == "transport-belt" then
            local speed = entity.prototype.belt_speed or 0
            if speed > best_speed then
                best, best_speed = entity.name, speed
            end
        end
    end
    return best or "transport-belt"
end

local function make_belt(surface, force, anchor, at, direction, name)
    return surface.create_entity({
        name = name,
        position = tile_centre(anchor, at),
        direction = direction or defines.direction.east,
        force = force,
    })
end

--- Hand over the modules a blueprint asked for. A ghost's item request is for
--- robots to deliver; there are none here, so the entity is given them directly.
local function fill_requests(entity, proxy, counts)
    if not (proxy and proxy.valid) then
        return
    end
    local ok = pcall(function()
        for _, plan in pairs(proxy.insert_plan) do
            for _, where in pairs(plan.items.in_inventory or {}) do
                counts.requested = counts.requested + where.count
                local inventory = entity.get_inventory(where.inventory)
                if inventory then
                    local stack = inventory[where.stack + 1]
                    if stack and stack.set_stack({ name = plan.id.name, count = where.count, quality = plan.id.quality }) then
                        counts.given = counts.given + where.count
                    end
                end
            end
        end
    end)
    if not ok then
        counts.errors = counts.errors + 1
    end
end

--- Build everything for a run and register it in storage. Raises on anything
--- unexpected; `start` turns that into an answer.
local function check_point(label, at)
    if type(at) ~= "table" or type(at[1]) ~= "number" or type(at[2]) ~= "number" then
        error(label .. " needs \"at\": [x, y]")
    end
end

local function check_direction(label, direction)
    if direction ~= nil and (type(direction) ~= "number" or direction < 0 or direction > 15 or direction % 1 ~= 0) then
        error(label .. " has an invalid direction")
    end
end

--- Reject a spec that would fail halfway, before anything is created.
local function validate(spec)
    local seconds = { warmup_s = spec.warmup_s, measure_s = spec.measure_s }
    for field, value in pairs(seconds) do
        if type(value) ~= "number" then
            error(field .. " is not a number")
        end
    end
    if spec.measure_s ~= nil and (spec.measure_s <= 0 or spec.measure_s > MAX_SECONDS) then
        error("measure_s must be above 0 and at most " .. MAX_SECONDS)
    end
    if spec.warmup_s ~= nil and (spec.warmup_s < 0 or spec.warmup_s > MAX_SECONDS) then
        error("warmup_s must be between 0 and " .. MAX_SECONDS)
    end
    for index, source in pairs(spec.sources or {}) do
        local label = "source " .. index
        check_point(label, source.at)
        check_direction(label, source.direction)
        if source.fluid then
            if not prototypes.fluid[source.fluid] then
                error(label .. ": unknown fluid " .. tostring(source.fluid))
            end
        else
            for _, item in pairs(source.items or {}) do
                if not prototypes.item[item] then
                    error(label .. ": unknown item " .. tostring(item))
                end
            end
        end
    end
    for index, output in pairs(spec.outputs or {}) do
        local label = "output " .. index
        check_point(label, output.at)
        check_direction(label, output.direction)
    end
    if spec.lanes ~= nil and type(spec.lanes) ~= "boolean" then
        error("lanes must be true or false")
    end
end

local function prepare(player, spec, m)
    local problems = {}
    local force = player and player.force or game.forces["player"]
    m.force = force

    local inventory = game.create_inventory(1)
    m.inventory = inventory
    local failed = inventory[1].import_stack(spec.blueprint) == 1
    local stack = inventory[1]
    if failed or not stack.valid_for_read or not stack.is_blueprint or not stack.is_blueprint_setup() then
        error("the spec's blueprint is not a blueprint")
    end
    local entries = stack.get_blueprint_entities() or {}

    local surface, surface_report = new_surface(spec.surface)
    m.surface = surface

    -- Chunks that reach the sources and sinks too, which can stand outside the
    -- blueprint's own entities.
    local reach_entries = {}
    for _, entry in pairs(entries) do
        reach_entries[#reach_entries + 1] = entry
    end
    for _, group in pairs({ spec.sources or {}, spec.outputs or {} }) do
        for _, item in pairs(group) do
            if item.at then
                reach_entries[#reach_entries + 1] = { position = { x = item.at[1], y = item.at[2] } }
            end
        end
    end
    local origin = { x = 0, y = 0 }
    scratch.prepare(surface, reach_entries, origin)

    local ghosts = stack.build_blueprint({
        surface = surface, force = force, position = origin, build_mode = defines.build_mode.forced })

    local built, refused = {}, {}
    local requests = { requested = 0, given = 0, errors = 0 }
    for _, ghost in pairs(ghosts) do
        if ghost.valid then
            if ghost.name == "entity-ghost" then
                local name = ghost.ghost_name
                local _, revived, proxy = ghost.revive({ return_item_request_proxy = true })
                if revived then
                    built[#built + 1] = revived
                    fill_requests(revived, proxy, requests)
                else
                    refused[name] = (refused[name] or 0) + 1
                end
            else
                built[#built + 1] = ghost
            end
        end
    end
    inventory.destroy()
    m.inventory = nil

    local anchor = find_anchor(entries, built)
    if not anchor then
        error("nothing from the blueprint stands on the measuring surface")
    end
    if anchor.matched < #built then
        problems[#problems + 1] = string.format(
            "the blueprint's coordinates fit %d of %d entities that stand", anchor.matched, #built)
    end

    -- A recipe the save has not unlocked would stop its machine. Unlocking is a
    -- flag on the force; it is switched back off when the run ends.
    local unlocked = m.unlocked
    for _, entity in pairs(built) do
        if entity.valid and (entity.type == "assembling-machine" or entity.type == "furnace") then
            local ok, recipe = pcall(function() return entity.get_recipe() end)
            if ok and recipe and not recipe.enabled then
                recipe.enabled = true
                unlocked[#unlocked + 1] = recipe.name
            end
        end
    end

    -- Power, after everything stands so that no pole can take a tile.
    local lo_x, lo_y, hi_x, hi_y = math.huge, math.huge, -math.huge, -math.huge
    for _, entity in pairs(built) do
        lo_x, hi_x = math.min(lo_x, entity.position.x), math.max(hi_x, entity.position.x)
        lo_y, hi_y = math.min(lo_y, entity.position.y), math.max(hi_y, entity.position.y)
    end
    local power = scratch.power(surface, force, {
        min_x = lo_x - 4, min_y = lo_y - 4, max_x = hi_x + 4, max_y = hi_y + 4 })
    power.kind = "forge-power-source (electric-energy-interface, one gigawatt) with invisible poles"

    local extra_belt = belt_name(built)

    -- Supply.
    local sources = {}
    for index, source in pairs(spec.sources or {}) do
        local record = { at = source.at, index = index, rate = source.rate }
        if source.fluid then
            record.kind = "fluid"
            record.fluid = source.fluid
            local spot = tile_centre(anchor, source.at)
            local there = surface.find_entities_filtered({ position = spot, limit = 1 })[1]
            if there and (there.type == "pipe") then
                there.destroy()
                there = nil
            end
            if there then
                record.problem = "the tile is taken by a " .. there.name
            else
                local pipe = surface.create_entity({ name = "infinity-pipe", position = spot, force = force })
                if pipe then
                    pipe.set_infinity_pipe_filter({
                        name = source.fluid, percentage = 1, mode = "exactly", temperature = source.temperature })
                    record.entity = pipe
                else
                    record.problem = "an infinity pipe could not be placed"
                end
            end
        else
            record.kind = "belt"
            local belt = belt_at(surface, anchor, source.at)
            if not belt then
                belt = make_belt(surface, force, anchor, source.at, source.direction, extra_belt)
                record.added_belt = belt ~= nil
            end
            if not belt then
                record.problem = "no belt at the tile and none could be placed"
            else
                record.entity = belt
                local items = source.items or {}
                local left, right = items[1], items[2] or items[1]
                -- Lane 1 is the left lane of the belt's direction, lane 2 the right.
                -- `rate` is both lanes together, as in the plan; none means as much as the belt takes.
                local each = source.rate and (source.rate / 2) or nil
                record.lanes = {
                    { index = 1, item = left, rate = each, tokens = 0, fed = 0 },
                    { index = 2, item = right, rate = each, tokens = 0, fed = 0 },
                }
            end
        end
        if record.problem then
            problems[#problems + 1] = "source at " .. serpent.line(source.at) .. ": " .. record.problem
        end
        sources[#sources + 1] = record
    end

    -- Sinks, one per tile.
    local sinks, by_tile = {}, {}
    for _, output in pairs(spec.outputs or {}) do
        local id = output.at[1] .. "," .. output.at[2]
        local sink = by_tile[id]
        if not sink then
            sink = { at = output.at, declared = {}, taken = {}, lanes = { {}, {} } }
            local belt = belt_at(surface, anchor, output.at)
            if not belt then
                belt = make_belt(surface, force, anchor, output.at, output.direction, extra_belt)
                sink.added_belt = belt ~= nil
            end
            if belt then
                sink.entity = belt
            else
                sink.problem = "no belt at the tile and none could be placed"
                problems[#problems + 1] = "output at " .. serpent.line(output.at) .. ": " .. sink.problem
            end
            by_tile[id] = sink
            sinks[#sinks + 1] = sink
        end
        if output.item then
            sink.declared[#sink.declared + 1] = output.item
        end
    end

    -- Machines to watch.
    local machines = {}
    local types = {}
    for _, kind in pairs(MACHINE_TYPES) do
        types[kind] = true
    end
    for _, entity in pairs(built) do
        if entity.valid and types[entity.type] then
            local recipe = nil
            pcall(function()
                local r = entity.get_recipe()
                recipe = r and r.name
            end)
            machines[#machines + 1] = {
                entity = entity, name = entity.name, recipe = recipe,
                position = { x = entity.position.x - anchor.x, y = entity.position.y - anchor.y },
                counts = {}, missing = {}, samples = 0,
            }
        end
    end

    local warmup = math.floor((spec.warmup_s or 60) * constants.ticks_per_second)
    local measure = math.floor((spec.measure_s or 120) * constants.ticks_per_second)

    local filled = {
        spec_surface = spec.surface,
        surface = surface,
        force = force,
        surface_report = surface_report,
        anchor = anchor,
        expected = #entries,
        placed = #built,
        refused = refused,
        unlocked = unlocked,
        modules = requests,
        power = power,
        sources = sources,
        sinks = sinks,
        machines = machines,
        problems = problems,
        lanes = spec.lanes == true,
        warmup = warmup,
        measure = measure,
        ticks = 0,
        phase = "warmup",
        started_at = game.tick,
        written = false,
    }
    for field, value in pairs(filled) do
        m[field] = value
    end
    if spec.speed and spec.speed > 0 then
        game.speed = math.min(spec.speed, 100)
    end
    script.on_nth_tick(1, M.on_tick)
end

local function totals(statistics)
    local copy = { input = {}, output = {} }
    if not statistics then
        return copy
    end
    local ok = pcall(function()
        for name, count in pairs(statistics.input_counts) do
            copy.input[tostring(name)] = count
        end
        for name, count in pairs(statistics.output_counts) do
            copy.output[tostring(name)] = count
        end
    end)
    return copy
end

local function stats_now(m)
    local items, fluids
    pcall(function() items = m.force.get_item_production_statistics(m.surface) end)
    pcall(function() fluids = m.force.get_fluid_production_statistics(m.surface) end)
    return { items = totals(items), fluids = totals(fluids) }
end

local function per_second(now, before, seconds)
    local out = {}
    for name, count in pairs(now) do
        local change = count - (before[name] or 0)
        if change ~= 0 then
            out[name] = change / seconds
        end
    end
    return out
end

local function feed(m)
    for _, source in pairs(m.sources) do
        if source.lanes and source.entity and source.entity.valid then
            for _, lane in pairs(source.lanes) do
                if lane.item then
                    local line = source.entity.get_transport_line(lane.index)
                    if lane.rate then
                        lane.tokens = math.min(lane.tokens + lane.rate / constants.ticks_per_second, TOKEN_CAP)
                    else
                        lane.tokens = 1
                    end
                    while lane.tokens >= 1 and line.can_insert_at_back() do
                        if not line.insert_at_back({ name = lane.item }) then
                            break
                        end
                        lane.tokens = lane.tokens - 1
                        lane.fed = lane.fed + 1
                        lane.total = (lane.total or 0) + 1
                    end
                end
            end
        end
    end
end

local function drain(m)
    for _, sink in pairs(m.sinks) do
        if sink.entity and sink.entity.valid then
            for index = 1, sink.entity.get_max_transport_line_index() do
                local line = sink.entity.get_transport_line(index)
                for _, content in pairs(line.get_contents()) do
                    local removed = line.remove_item({ name = content.name, count = content.count, quality = content.quality })
                    if removed > 0 then
                        -- Odd transport lines are the left lane, even ones the right, on every
                        -- belt type (a transport belt has 2 lines, an underground 4, a splitter 8).
                        local lane = sink.lanes[(index - 1) % 2 + 1]
                        lane[content.name] = (lane[content.name] or 0) + removed
                        sink.taken[content.name] = (sink.taken[content.name] or 0) + removed
                    end
                end
            end
        end
    end
end

local function sample(m, names)
    for _, machine in pairs(m.machines) do
        local entity = machine.entity
        if entity.valid then
            local status = names[entity.status] or "none"
            local group = STATUS_GROUP[status] or "other"
            machine.counts[group] = (machine.counts[group] or 0) + 1
            machine.samples = machine.samples + 1
            if group == "other" then
                machine.other = machine.other or {}
                machine.other[status] = (machine.other[status] or 0) + 1
            elseif group == "waiting_input" then
                -- Which ingredient is not there is the reason worth writing down.
                pcall(function()
                    local recipe = entity.get_recipe()
                    if recipe then
                        for _, ingredient in pairs(recipe.ingredients) do
                            local have
                            if ingredient.type == "fluid" then
                                have = entity.get_fluid_count(ingredient.name)
                            else
                                have = entity.get_item_count(ingredient.name)
                            end
                            if have < ingredient.amount then
                                machine.missing[ingredient.name] = (machine.missing[ingredient.name] or 0) + 1
                            end
                        end
                    end
                end)
            end
        end
    end
end

local function finish(m)
    local seconds = m.measure / constants.ticks_per_second
    local after = stats_now(m)
    local before = m.stats_before

    local sources = {}
    for _, source in pairs(m.sources) do
        local entry = { at = source.at, kind = source.kind, declared_rate = source.rate, fluid = source.fluid,
                        problem = source.problem, added_belt = source.added_belt }
        if source.kind == "fluid" then
            entry.note = "an infinity pipe: the supply is not limited to the declared rate"
        end
        if source.lanes then
            entry.lanes = {}
            for _, lane in pairs(source.lanes) do
                entry.lanes[#entry.lanes + 1] = {
                    lane = lane.index == 1 and "left" or "right", item = lane.item,
                    declared_rate = lane.rate, fed_rate = lane.fed / seconds }
            end
        end
        sources[#sources + 1] = entry
    end

    local outputs = {}
    for _, sink in pairs(m.sinks) do
        local taken = {}
        for name, count in pairs(sink.taken) do
            taken[name] = count / seconds
        end
        local per_lane
        if m.lanes then
            -- Line 1 is the left lane and line 2 the right, seen along the belt's own direction.
            -- A lane that carried nothing is left out; if neither did, the field is left out.
            for index, side in ipairs({ "left", "right" }) do
                for name, count in pairs(sink.lanes[index]) do
                    per_lane = per_lane or {}
                    per_lane[side] = per_lane[side] or {}
                    per_lane[side][name] = count / seconds
                end
            end
        end
        outputs[#outputs + 1] = {
            lanes = per_lane,
            at = sink.at, declared_items = sink.declared, delivered = taken,
            problem = sink.problem, added_belt = sink.added_belt }
    end

    -- What everything else that has a status was doing at the end: an inserter that
    -- reports no power, or a belt end nobody reaches, shows up here.
    local others = {}
    local names = status_names()
    for _, entity in pairs(m.surface.find_entities_filtered({ force = m.force })) do
        if entity.status ~= nil and entity.name ~= constants.source then
            local by_name = others[entity.name]
            if not by_name then
                by_name = {}
                others[entity.name] = by_name
            end
            local status = names[entity.status] or "none"
            by_name[status] = (by_name[status] or 0) + 1
        end
    end

    local machines = {}
    for _, machine in pairs(m.machines) do
        local shares = {}
        for _, group in pairs(GROUPS) do
            shares[group] = machine.samples > 0 and ((machine.counts[group] or 0) / machine.samples) or 0
        end
        local missing = {}
        for name, count in pairs(machine.missing) do
            missing[name] = machine.samples > 0 and (count / machine.samples) or 0
        end
        local finished = nil
        if machine.entity.valid then
            pcall(function() finished = machine.entity.products_finished - (machine.finished_before or 0) end)
        end
        machines[#machines + 1] = {
            name = machine.name, recipe = machine.recipe, position = machine.position,
            samples = machine.samples, shares = shares, missing = missing,
            other = machine.other, products_finished = finished }
    end

    write_result({
        ok = true,
        surface = m.surface_report,
        anchor = { x = m.anchor.x, y = m.anchor.y, matched = m.anchor.matched },
        placed = m.placed,
        expected = m.expected,
        refused = m.refused,
        recipes_unlocked_for_the_run = m.unlocked,
        modules = m.modules,
        power = m.power,
        window = { warmup_s = m.warmup / constants.ticks_per_second, measure_s = seconds,
                   speed = game.speed, how = "production statistics of the measuring surface and counts at the sinks" },
        sources = sources,
        outputs = outputs,
        produced = per_second(after.items.input, before.items.input, seconds),
        consumed = per_second(after.items.output, before.items.output, seconds),
        fluids_produced = per_second(after.fluids.input, before.fluids.input, seconds),
        fluids_consumed = per_second(after.fluids.output, before.fluids.output, seconds),
        machines = machines,
        final_status = others,
        problems = m.problems,
    })
end

local function cleanup(m)
    script.on_nth_tick(1, nil)
    if m.inventory and m.inventory.valid then
        m.inventory.destroy()
    end
    -- Recipes switched on for the run go back off, so that a measurement in a live
    -- game leaves the player's research exactly as it was.
    for _, name in pairs(m.unlocked or {}) do
        pcall(function() m.force.recipes[name].enabled = false end)
    end
    if m.speed_before then
        game.speed = m.speed_before
    end
    if m.surface and m.surface.valid then
        game.delete_surface(m.surface)
    end
    storage.measure = nil
end

local function begin_window(m)
    m.phase = "measure"
    m.stats_before = stats_now(m)
    for _, source in pairs(m.sources) do
        for _, lane in pairs(source.lanes or {}) do
            lane.fed = 0
        end
    end
    for _, sink in pairs(m.sinks) do
        sink.taken = {}
        sink.lanes = { {}, {} }
    end
    for _, machine in pairs(m.machines) do
        machine.counts, machine.missing, machine.samples, machine.other = {}, {}, 0, nil
        pcall(function() machine.finished_before = machine.entity.products_finished end)
    end
end

local function tick(m)
    m.ticks = m.ticks + 1
    feed(m)
    drain(m)
    if m.phase == "warmup" then
        if m.ticks >= m.warmup then
            begin_window(m)
        end
        return
    end
    if (m.ticks - m.warmup) % SAMPLE_EVERY == 0 then
        sample(m, status_names())
    end
    if m.ticks >= m.warmup + m.measure then
        finish(m)
        cleanup(m)
    end
end

--- Every tick of a run.
function M.on_tick()
    local m = storage.measure
    if not m then
        script.on_nth_tick(1, nil)
        return
    end
    local ok, err = pcall(tick, m)
    if not ok then
        write_result({ ok = false, error = tostring(err), at_tick = m.ticks, problems = m.problems })
        pcall(cleanup, m)
    end
end

--- `/forge-measure <spec json>`
function M.start(player, text)
    if storage.measure then
        say(player, "Forge: a measurement is already running.")
        return
    end
    local spec = helpers.json_to_table(text or "")
    if type(spec) ~= "table" or type(spec.blueprint) ~= "string" then
        write_result({ ok = false, error = "the spec is not JSON with a \"blueprint\" string" })
        say(player, "Forge: the spec is not JSON with a blueprint string.")
        return
    end
    if storage.run or storage.pending_start then
        say(player, "Forge: a circuit run is going; finish or /forge-clean it first.")
        return
    end
    local valid, invalid = pcall(validate, spec)
    if not valid then
        local failure = tostring(invalid)
        write_result({ ok = false, error = failure })
        say(player, "Forge: could not set the measurement up: " .. failure)
        return
    end
    -- The record exists before the first side effect, so a failure halfway can be undone.
    local m = { unlocked = {}, speed_before = game.speed }
    storage.measure = m
    local ok, err = pcall(prepare, player, spec, m)
    if not ok then
        local failure = tostring(err)
        pcall(cleanup, m)
        write_result({ ok = false, error = failure })
        say(player, "Forge: could not set the measurement up: " .. failure)
        return
    end
    say(player, string.format("Forge: measuring %d of %d entities for %d + %d game seconds.",
        m.placed, m.expected, m.warmup / constants.ticks_per_second, m.measure / constants.ticks_per_second))
end

--- Stop a run and undo it; returns true when there was one.
function M.abort()
    local m = storage.measure
    if not m then
        return false
    end
    pcall(cleanup, m)
    return true
end

--- A saved game that was loaded in the middle of a run carries on with it.
function M.on_load()
    if storage.measure then
        script.on_nth_tick(1, M.on_tick)
    end
end

return M
