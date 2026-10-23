--- `/forge-survey`: watch the base for a while and write what it is doing.
---
--- The review of an existing base needs facts only the running game has: what
--- every machine is doing (as a share of a window, not one tick's luck), which
--- ingredient it waits for, what the drills sit on, what flows through the
--- surface, how the power networks fare, and the layout itself as a blueprint.
--- This file samples all of it once a second over the window and writes
--- `survey.json`; the format is described in factorio-forge's survey module and
--- in the README.
---
--- The world is never changed. A blueprint is made in a scratch inventory that
--- is destroyed again; everything else is read.
---
--- The command runs with no player (a server console or RCON): the surface is
--- then named in the command and the answer goes to the log and to everyone's
--- chat instead of to one player.

local constants = require("constants")

local M = {}

local OUTPUT = "factorio-forge/"
local FILE = OUTPUT .. "survey.json"

local DEFAULT_SECONDS, MIN_SECONDS, MAX_SECONDS = 60, 5, 3600
local SAMPLE_EVERY = 60 -- ticks: once a second

-- Resource patches. Two resource tiles belong to one patch when they are no
-- more than LINK tiles apart in both directions (so up to two empty tiles may
-- lie between them). The search for a patch is bounded so a huge map cannot
-- stall the game: at most MAX_FIELD_ENTITIES resource entities are looked at in
-- one search box, and the box (around a group of nearby drills) is widened at
-- most MAX_ROUNDS - 1 times, the margin doubling each time (8, 16, 32 ... tiles);
-- a patch that still reaches the edge of the box, or was cut by the entity cap,
-- is written with "truncated": true (its size is then a lower bound).
local LINK = 3
local MAX_FIELD_ENTITIES = 100000
local MAX_ROUNDS = 6
local MARGIN = 8
-- Drills no further apart than this (in both directions) are searched together;
-- drills of one resource farther apart get a search box each.
local GROUP_GAP = 48

-- Resources no drill mines ("unmined"): the nearest patch is looked for in
-- charted chunks only, outward from the surveyed box in rings of RING_WIDTH
-- tiles, up to SEARCH_RADIUS tiles from the box; the first ring that holds
-- the resource ends the search for it (the next ring is read too, since the
-- corner of a ring can lie farther away than the near edge of the next one).
-- The box itself is searched first: a patch inside the base that nothing mines
-- is at distance 0. A resource with no entity at all in the whole band is
-- skipped after one cheap count. One strip search reads at most
-- MAX_RING_ENTITIES entities (a hit on that cap can leave a nearer tile of the
-- resource unseen; "truncated" does not say so, it only marks the amount).
-- Infinite resources (oil, geysers) are left out: they have a yield, not a patch.
local SEARCH_RADIUS = 400
local RING_WIDTH = 64
local MAX_RING_ENTITIES = 20000

-- Enemy spawners and worms count as "near" a patch when they stand within
-- ENEMY_RADIUS tiles of its box; at most MAX_ENEMY_ENTITIES are read per patch.
local ENEMY_RADIUS = 32
local MAX_ENEMY_ENTITIES = 5000
-- Demolishers (segmented units) roam a territory, so they are counted per
-- territory that covers a chunk within ENEMY_RADIUS of the box; at most
-- MAX_TERRITORY_CHUNKS chunks are looked up (a larger box is sampled).
local MAX_TERRITORY_CHUNKS = 1024

-- Entity statuses that mean "waiting for something to craft with".
local WAITING_INPUT = {
    no_ingredients = true,
    item_ingredient_shortage = true,
    fluid_ingredient_shortage = true,
    no_input_fluid = true,
    low_input_fluid = true,
    missing_required_fluid = true,
    missing_science_packs = true,
}
-- Statuses that say the power network could not keep up.
local POWER_SHORT = {
    low_power = true,
    no_power = true,
    recharging_after_power_outage = true,
}

local function say(player, message)
    if player then
        player.print(message)
    elseif rcon then
        rcon.print(message)
    end
end

--- A message for whoever asked, from inside a tick: no command is running any
--- more, so a console or RCON caller can only be reached through the chat and
--- the log.
local function announce(s, message)
    log(message)
    local player = s.player_index and game.get_player(s.player_index)
    if player and player.valid then
        player.print(message)
    else
        game.print(message)
    end
end

local function write_failure(message)
    helpers.write_file(FILE, helpers.table_to_json({
        exported_by = "factorio-forge-companion",
        kind = "survey-failed",
        error = message,
    }), false)
end

local function status_names()
    local names = {}
    for name, value in pairs(defines.entity_status) do
        names[value] = name
    end
    return names
end

local function round(value, places)
    local scale = 10 ^ places
    return math.floor(value * scale + 0.5) / scale
end

local function pos(entity_or_position)
    local p = entity_or_position.position or entity_or_position
    return { round(p.x or p[1], 2), round(p.y or p[2], 2) }
end

local function read(object, key)
    local ok, value = pcall(function() return object[key] end)
    if ok then
        return value
    end
    return nil
end

local function crafting_types()
    local seen, list = {}, {}
    local ok = pcall(function()
        for _, proto in pairs(prototypes.get_entity_filtered({ { filter = "crafting-machine" } })) do
            if not seen[proto.type] then
                seen[proto.type] = true
                list[#list + 1] = proto.type
            end
        end
    end)
    if not ok or #list == 0 then
        list = { "assembling-machine", "furnace", "rocket-silo" }
    end
    return list
end

--- The area of a command word `x1,y1,x2,y2`, put in order; nil when malformed.
local function parse_area(text)
    local numbers = {}
    for piece in string.gmatch(text, "[^,]+") do
        local n = tonumber(piece)
        if not n then
            return nil
        end
        numbers[#numbers + 1] = n
    end
    if #numbers ~= 4 then
        return nil
    end
    return {
        left_top = { x = math.min(numbers[1], numbers[3]), y = math.min(numbers[2], numbers[4]) },
        right_bottom = { x = math.max(numbers[1], numbers[3]), y = math.max(numbers[2], numbers[4]) },
    }
end

--- The command's words: seconds, surface=, area=. Returns a table, or nil and the reason.
local function parse(text)
    local out = { seconds = DEFAULT_SECONDS }
    for word in string.gmatch(text or "", "%S+") do
        local seconds = tonumber(word)
        local surface = string.match(word, "^surface=(.+)$")
        local area = string.match(word, "^area=(.+)$")
        if seconds then
            if seconds < MIN_SECONDS or seconds > MAX_SECONDS then
                return nil, string.format("seconds must be between %d and %d", MIN_SECONDS, MAX_SECONDS)
            end
            out.seconds = seconds
        elseif surface then
            out.surface = surface
        elseif area then
            out.area = parse_area(area)
            if not out.area then
                return nil, "area is x1,y1,x2,y2 (four numbers)"
            end
        else
            return nil, "unknown word: " .. word
        end
    end
    return out
end

--- The box around everything the force has on the surface (not counting the
--- characters walking about, nor ghosts).
local function default_area(surface, force)
    local x1, y1, x2, y2
    for _, entity in pairs(surface.find_entities_filtered({ force = force })) do
        local kind = entity.type
        if kind ~= "character" and kind ~= "entity-ghost" and kind ~= "tile-ghost" then
            local p = entity.position
            x1 = x1 and math.min(x1, p.x) or p.x
            y1 = y1 and math.min(y1, p.y) or p.y
            x2 = x2 and math.max(x2, p.x) or p.x
            y2 = y2 and math.max(y2, p.y) or p.y
        end
    end
    if not x1 then
        return nil
    end
    return {
        left_top = { x = math.floor(x1) - 1, y = math.floor(y1) - 1 },
        right_bottom = { x = math.ceil(x2) + 1, y = math.ceil(y2) + 1 },
    }
end

local function recipe_name_of(entity)
    local ok, recipe = pcall(function() return entity.get_recipe() end)
    if ok and recipe then
        return recipe.name
    end
    if entity.type == "furnace" then
        local previous = read(entity, "previous_recipe")
        if previous then
            -- `name` may come back as a prototype object rather than a string.
            local name = read(previous, "name")
            if type(name) ~= "string" then
                name = name and read(name, "valid") and read(name, "name") or nil
            end
            if type(name) == "string" then
                return name
            end
        end
    end
    return nil
end

local INPUT_INVENTORIES = { "crafter_input", "assembling_machine_input", "furnace_source" }

local function input_inventory(entity)
    for _, name in pairs(INPUT_INVENTORIES) do
        local index = defines.inventory[name]
        if index then
            local ok, inventory = pcall(function() return entity.get_inventory(index) end)
            if ok and inventory then
                return inventory
            end
        end
    end
    return nil
end

--- Which ingredients of the recipe the machine does not hold enough of right
--- now: items in its input inventory, fluids in its fluid boxes.
local function short_ingredients(entity, recipe_name)
    local proto = recipe_name and prototypes.recipe[recipe_name]
    if not proto then
        return {}
    end
    local held = {}
    local inventory = input_inventory(entity)
    if inventory then
        pcall(function()
            for _, stack in pairs(inventory.get_contents()) do
                held[stack.name] = (held[stack.name] or 0) + stack.count
            end
        end)
    end
    local fluids = {}
    pcall(function()
        for index = 1, #entity.fluidbox do
            local fluid = entity.fluidbox[index]
            if fluid then
                fluids[fluid.name] = (fluids[fluid.name] or 0) + fluid.amount
            end
        end
    end)
    local short = {}
    for _, ingredient in pairs(proto.ingredients) do
        local have = (ingredient.type == "fluid") and fluids[ingredient.name] or held[ingredient.name]
        if (have or 0) < ingredient.amount then
            short[#short + 1] = ingredient.name
        end
    end
    return short
end

local function electric_network(entity)
    local id = read(entity, "electric_network_id")
    if type(id) == "number" then
        return id
    end
    return nil
end

--- Made and used totals of a flow statistics object. For items and fluids the
--- game's input side is what was made and the output side what was used; an
--- electric network's statistics are the other way round (input holds the
--- consumers, output the producers -- checked in the game), hence `electric`.
local function counts(statistics, electric)
    local made, used = {}, {}
    if not statistics then
        return { made = made, used = used }
    end
    pcall(function()
        local made_side = electric and statistics.output_counts or statistics.input_counts
        local used_side = electric and statistics.input_counts or statistics.output_counts
        for name, count in pairs(made_side) do
            made[tostring(name)] = count
        end
        for name, count in pairs(used_side) do
            used[tostring(name)] = count
        end
    end)
    return { made = made, used = used }
end

local function sum(table_of_numbers)
    local total = 0
    for _, n in pairs(table_of_numbers) do
        total = total + n
    end
    return total
end

local function production_now(s)
    local items, fluids
    pcall(function() items = s.force.get_item_production_statistics(s.surface) end)
    pcall(function() fluids = s.force.get_fluid_production_statistics(s.surface) end)
    return { items = counts(items), fluids = counts(fluids) }
end

local function flows_between(now, before, seconds)
    local out = {}
    for _, kind in pairs({ "items", "fluids" }) do
        local table_out = {}
        local names = {}
        for name in pairs(now[kind].made) do names[name] = true end
        for name in pairs(now[kind].used) do names[name] = true end
        for name in pairs(names) do
            local made = ((now[kind].made[name] or 0) - (before[kind].made[name] or 0)) / seconds
            local used = ((now[kind].used[name] or 0) - (before[kind].used[name] or 0)) / seconds
            if made ~= 0 or used ~= 0 then
                table_out[name] = { made = round(made, 4), used = round(used, 4) }
            end
        end
        if next(table_out) then
            out[kind] = table_out
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Resource patches
---------------------------------------------------------------------------

local function key(x, y)
    return x .. "," .. y
end

--- Resource entities under a drill's mining area, by kind: {name -> list}.
local function resources_under(surface, drill)
    local radius = 0.5
    pcall(function() radius = drill.prototype.mining_drill_radius or 0.5 end)
    local p = drill.position
    local under = {}
    pcall(function()
        for _, resource in pairs(surface.find_entities_filtered({
            area = { { p.x - radius, p.y - radius }, { p.x + radius, p.y + radius } },
            type = "resource",
        })) do
            local list = under[resource.name]
            if not list then
                list = {}
                under[resource.name] = list
            end
            list[#list + 1] = resource
        end
    end)
    return under
end

--- Cluster the resource entities of one kind found in `box`; returns the
--- entities, their cluster index (union-find roots) and whether the bound hit.
local function cluster(surface, name, box)
    -- `limit` makes the cap bound the work, not only the list kept afterwards.
    local found = surface.find_entities_filtered({
        area = box, name = name, type = "resource", limit = MAX_FIELD_ENTITIES + 1 })
    local truncated = false
    if #found > MAX_FIELD_ENTITIES then
        truncated = true
        found[#found] = nil
    end
    local parent = {}
    local function root(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    local grid = {}
    local cells = {}
    for i, entity in ipairs(found) do
        parent[i] = i
        local p = entity.position
        local cx, cy = math.floor(p.x / LINK), math.floor(p.y / LINK)
        cells[i] = { cx, cy }
        local cell = key(cx, cy)
        grid[cell] = grid[cell] or {}
        table.insert(grid[cell], i)
    end
    for i, entity in ipairs(found) do
        local p = entity.position
        local cx, cy = cells[i][1], cells[i][2]
        for dx = -1, 1 do
            for dy = -1, 1 do
                local others = grid[key(cx + dx, cy + dy)]
                if others then
                    for _, j in ipairs(others) do
                        if j > i then
                            local q = found[j].position
                            if math.abs(p.x - q.x) <= LINK and math.abs(p.y - q.y) <= LINK then
                                local a, b = root(i), root(j)
                                if a ~= b then
                                    parent[a] = b
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local roots = {}
    for i = 1, #found do
        roots[i] = root(i)
    end
    return found, roots, truncated
end

--- Cluster the resource entities of one kind around the seed tiles (keys of
--- "x,y"), widening the search box until the patches the seeds touch lie well
--- inside it or the rounds are used up. `x1..y2` bound the seed tiles. Returns
--- the entities, their cluster roots, whether the entity cap hit, and the box.
local function widen(surface, name, seed_keys, x1, y1, x2, y2)
    local margin = MARGIN
    local box = { { x1 - margin, y1 - margin }, { x2 + margin, y2 + margin } }
    local found, roots, capped
    for round = 1, MAX_ROUNDS do
        found, roots, capped = cluster(surface, name, box)
        -- The patches the seeds touch, and how far they reach.
        local seeded = {}
        for i, entity in ipairs(found) do
            local p = entity.position
            if seed_keys[key(p.x, p.y)] then
                seeded[roots[i]] = true
            end
        end
        local gx1, gy1, gx2, gy2
        for i, entity in ipairs(found) do
            if seeded[roots[i]] then
                local p = entity.position
                gx1 = gx1 and math.min(gx1, p.x) or p.x
                gy1 = gy1 and math.min(gy1, p.y) or p.y
                gx2 = gx2 and math.max(gx2, p.x) or p.x
                gy2 = gy2 and math.max(gy2, p.y) or p.y
            end
        end
        local inside = gx1 == nil or (
            gx1 - LINK > box[1][1] and gy1 - LINK > box[1][2]
            and gx2 + LINK < box[2][1] and gy2 + LINK < box[2][2])
        if capped or inside or round == MAX_ROUNDS then
            break
        end
        -- Each widening doubles the margin, so a few rounds reach far.
        margin = margin * 2
        box = { { gx1 - margin, gy1 - margin }, { gx2 + margin, gy2 + margin } }
    end
    return found, roots, capped, box
end

--- Drills of one resource, split into groups of drills that lie near each other
--- (no more than GROUP_GAP tiles apart), so that two outposts far apart are
--- searched on their own and not through one box spanning the map between them.
local function group_drills(list)
    local parent = {}
    local function root(i)
        while parent[i] ~= i do
            parent[i] = parent[parent[i]]
            i = parent[i]
        end
        return i
    end
    local grid = {}
    local cells = {}
    for i, drill in ipairs(list) do
        parent[i] = i
        local p = drill.entity.position
        local cx, cy = math.floor(p.x / GROUP_GAP), math.floor(p.y / GROUP_GAP)
        cells[i] = { cx, cy }
        local cell = key(cx, cy)
        grid[cell] = grid[cell] or {}
        table.insert(grid[cell], i)
    end
    for i, drill in ipairs(list) do
        local p = drill.entity.position
        for dx = -1, 1 do
            for dy = -1, 1 do
                for _, j in ipairs(grid[key(cells[i][1] + dx, cells[i][2] + dy)] or {}) do
                    if j > i then
                        local q = list[j].entity.position
                        if math.abs(p.x - q.x) <= GROUP_GAP and math.abs(p.y - q.y) <= GROUP_GAP then
                            local a, b = root(i), root(j)
                            if a ~= b then
                                parent[a] = b
                            end
                        end
                    end
                end
            end
        end
    end
    local groups, by_root = {}, {}
    for i, drill in ipairs(list) do
        local r = root(i)
        local group = by_root[r]
        if not group then
            group = { first = drill.entity.unit_number }
            by_root[r] = group
            groups[#groups + 1] = group
        end
        group.first = math.min(group.first, drill.entity.unit_number)
        group[#group + 1] = drill
    end
    table.sort(groups, function(a, b) return a.first < b.first end)
    return groups
end

--- Enemy spawners, worms (turrets of a force that is an enemy of `force`) and
--- demolishers (segmented units guarding a territory that reaches the box)
--- within ENEMY_RADIUS tiles of the box x1,y1..x2,y2. Always a table with the
--- three counts (an empty Lua table would be written as a JSON list, not an
--- object), so all zeros means none were found.
local function enemies_near(surface, force, x1, y1, x2, y2)
    local counts_by_kind = { spawners = 0, worms = 0, demolishers = 0 }
    local hostile = {}
    pcall(function()
        for _, other in pairs(game.forces) do
            if other ~= force and force.is_enemy(other) then
                hostile[#hostile + 1] = other
            end
        end
    end)
    if #hostile == 0 then
        return counts_by_kind
    end
    local area = { { x1 - ENEMY_RADIUS, y1 - ENEMY_RADIUS }, { x2 + ENEMY_RADIUS, y2 + ENEMY_RADIUS } }
    pcall(function()
        for _, entity in pairs(surface.find_entities_filtered({
            area = area, type = { "unit-spawner", "turret" }, force = hostile, limit = MAX_ENEMY_ENTITIES,
        })) do
            if entity.type == "unit-spawner" then
                counts_by_kind.spawners = counts_by_kind.spawners + 1
            else
                counts_by_kind.worms = counts_by_kind.worms + 1
            end
        end
    end)
    -- Demolishers: the territories of the chunks around the box, each unit once.
    local territory_ok = pcall(function()
        local cx1, cy1 = math.floor(area[1][1] / 32), math.floor(area[1][2] / 32)
        local cx2, cy2 = math.floor(area[2][1] / 32), math.floor(area[2][2] / 32)
        local total = (cx2 - cx1 + 1) * (cy2 - cy1 + 1)
        local step = math.max(1, math.ceil(math.sqrt(total / MAX_TERRITORY_CHUNKS)))
        local seen, n = {}, 0
        for cx = cx1, cx2, step do
            for cy = cy1, cy2, step do
                local territory = surface.get_territory_for_chunk({ x = cx, y = cy })
                if territory and territory.valid then
                    for _, unit in pairs(territory.get_segmented_units()) do
                        local id = unit.unit_number
                        if id and not seen[id] then
                            seen[id] = true
                            n = n + 1
                        end
                    end
                end
            end
        end
        counts_by_kind.demolishers = n
    end)
    if not territory_ok then
        -- A build without territories: look for the units themselves.
        pcall(function()
            counts_by_kind.demolishers = #surface.find_entities_filtered({
                area = area, type = "segmented-unit", force = hostile, limit = MAX_ENEMY_ENTITIES })
        end)
    end
    return counts_by_kind
end

--- Patches under the drills. `drills` holds {entity, name, under} where `name`
--- is the resource the drill mines and `under` the resource entities of that
--- name beneath it. Sets drill.field and returns the field records.
local function build_fields(surface, force, drills, first_id)
    local by_resource = {}
    for _, drill in ipairs(drills) do
        if drill.name then
            by_resource[drill.name] = by_resource[drill.name] or {}
            table.insert(by_resource[drill.name], drill)
        end
    end
    local names = {}
    for name in pairs(by_resource) do
        names[#names + 1] = name
    end
    table.sort(names)

    local fields = {}
    local next_id = first_id
    for _, name in ipairs(names) do
        -- Tiles already part of a patch found for an earlier group of drills.
        local claimed = {}
        local record_of_id = {}
        for _, group in ipairs(group_drills(by_resource[name])) do
            local pending = {}
            for _, drill in ipairs(group) do
                local id
                for _, resource in ipairs(drill.under) do
                    id = claimed[key(resource.position.x, resource.position.y)]
                    if id then break end
                end
                if id then
                    drill.field = id
                    record_of_id[id].drills = record_of_id[id].drills + 1
                else
                    pending[#pending + 1] = drill
                end
            end

            local seed_keys = {}
            local x1, y1, x2, y2
            for _, drill in ipairs(pending) do
                for _, resource in ipairs(drill.under) do
                    local p = resource.position
                    seed_keys[key(p.x, p.y)] = true
                    x1 = x1 and math.min(x1, p.x) or p.x
                    y1 = y1 and math.min(y1, p.y) or p.y
                    x2 = x2 and math.max(x2, p.x) or p.x
                    y2 = y2 and math.max(y2, p.y) or p.y
                end
            end
            if x1 then
                local found, roots, capped, box = widen(surface, name, seed_keys, x1, y1, x2, y2)

                local seeded, by_root = {}, {}
                for i, entity in ipairs(found) do
                    local p = entity.position
                    if seed_keys[key(p.x, p.y)] then
                        seeded[roots[i]] = true
                    end
                end
                for i, entity in ipairs(found) do
                    local r = roots[i]
                    if seeded[r] then
                        local f = by_root[r]
                        if not f then
                            f = { amount = 0, tiles = 0, sx = 0, sy = 0, drills = 0 }
                            by_root[r] = f
                        end
                        local p = entity.position
                        f.amount = f.amount + entity.amount
                        f.tiles = f.tiles + 1
                        f.sx = f.sx + p.x
                        f.sy = f.sy + p.y
                        f.x1 = f.x1 and math.min(f.x1, p.x) or p.x
                        f.y1 = f.y1 and math.min(f.y1, p.y) or p.y
                        f.x2 = f.x2 and math.max(f.x2, p.x) or p.x
                        f.y2 = f.y2 and math.max(f.y2, p.y) or p.y
                    end
                end
                -- A patch that reaches the edge of the searched box (or was cut
                -- by the entity cap) may go on beyond it: its size is a lower bound.
                for _, f in pairs(by_root) do
                    f.truncated = capped
                        or not (f.x1 - LINK > box[1][1] and f.y1 - LINK > box[1][2]
                            and f.x2 + LINK < box[2][1] and f.y2 + LINK < box[2][2])
                end
                -- Number the patches in a stable order (by their first tile) and
                -- hand each drill the patch of its first resource tile.
                local order = {}
                for r in pairs(by_root) do
                    order[#order + 1] = r
                end
                table.sort(order)
                local id_of_root = {}
                for _, r in ipairs(order) do
                    id_of_root[r] = next_id
                    by_root[r].id = next_id
                    by_root[r].resource = name
                    record_of_id[next_id] = by_root[r]
                    next_id = next_id + 1
                end
                local root_of_key = {}
                for i, entity in ipairs(found) do
                    local p = entity.position
                    local k = key(p.x, p.y)
                    root_of_key[k] = roots[i]
                    local id = id_of_root[roots[i]]
                    if id then
                        claimed[k] = id
                    end
                end
                for _, drill in ipairs(pending) do
                    for _, resource in ipairs(drill.under) do
                        local p = resource.position
                        local r = root_of_key[key(p.x, p.y)]
                        if r and id_of_root[r] then
                            drill.field = id_of_root[r]
                            by_root[r].drills = by_root[r].drills + 1
                            break
                        end
                    end
                end
                for _, r in ipairs(order) do
                    fields[#fields + 1] = by_root[r]
                end
            end
        end
    end
    local out = {}
    for _, f in ipairs(fields) do
        out[#out + 1] = {
            id = f.id,
            resource = f.resource,
            amount = round(f.amount, 0),
            tiles = f.tiles,
            drills = f.drills,
            center = { round(f.sx / f.tiles, 1), round(f.sy / f.tiles, 1) },
            truncated = f.truncated or nil,
            enemies = enemies_near(surface, force, f.x1, f.y1, f.x2, f.y2),
        }
    end
    return out
end

--- The resource prototypes that have a patch to speak of (not the infinite
--- ones), as {name -> true}.
local function finite_resources()
    local names = {}
    pcall(function()
        for name, proto in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "resource" } })) do
            if read(proto, "infinite_resource") ~= true then
                names[name] = true
            end
        end
    end)
    return names
end

--- Distance from the box `b` (left, top, right, bottom) to a point; 0 inside.
local function distance_to_box(b, x, y)
    local dx = math.max(b[1] - x, 0, x - b[3])
    local dy = math.max(b[2] - y, 0, y - b[4])
    return math.sqrt(dx * dx + dy * dy)
end

--- The four boxes of the ring between `inner` and `outer` tiles away from the
--- box `b`, as areas; they do not overlap.
local function ring_strips(b, inner, outer)
    local l, t, r, d = b[1], b[2], b[3], b[4]
    return {
        { { l - outer, t - outer }, { r + outer, t - inner } },
        { { l - outer, d + inner }, { r + outer, d + outer } },
        { { l - outer, t - inner }, { l - inner, d + inner } },
        { { r + inner, t - inner }, { r + outer, d + inner } },
    }
end

--- The nearest charted entity of resource `name` in the strips (areas), as
--- entity and distance from `bounds`; nothing farther than SEARCH_RADIUS.
local function nearest_in(surface, force, name, bounds, strips)
    local best, best_distance
    for _, strip in ipairs(strips) do
        local ok, found = pcall(function()
            return surface.find_entities_filtered({
                area = strip, name = name, type = "resource", limit = MAX_RING_ENTITIES })
        end)
        if ok then
            for _, entity in ipairs(found) do
                local p = entity.position
                if force.is_chunk_charted(surface, { x = math.floor(p.x / 32), y = math.floor(p.y / 32) }) then
                    local distance = distance_to_box(bounds, p.x, p.y)
                    if distance <= SEARCH_RADIUS and (not best_distance or distance < best_distance) then
                        best, best_distance = entity, distance
                    end
                end
            end
        end
    end
    return best, best_distance
end

--- The patch around `best` (flood as for the fields): amount, box and whether
--- the amount is only a lower bound.
local function measure_patch(surface, name, best)
    local p = best.position
    local seed = { [key(p.x, p.y)] = true }
    local found, roots, hit_cap, box = widen(surface, name, seed, p.x, p.y, p.x, p.y)
    local root
    for i, entity in ipairs(found) do
        local q = entity.position
        if seed[key(q.x, q.y)] then
            root = roots[i]
            break
        end
    end
    local amount, x1, y1, x2, y2 = 0, nil, nil, nil, nil
    for i, entity in ipairs(found) do
        if root and roots[i] == root then
            local q = entity.position
            amount = amount + entity.amount
            x1 = x1 and math.min(x1, q.x) or q.x
            y1 = y1 and math.min(y1, q.y) or q.y
            x2 = x2 and math.max(x2, q.x) or q.x
            y2 = y2 and math.max(y2, q.y) or q.y
        end
    end
    local truncated = hit_cap
    if x1 then
        truncated = truncated or not (x1 - LINK > box[1][1] and y1 - LINK > box[1][2]
            and x2 + LINK < box[2][1] and y2 + LINK < box[2][2])
    else
        x1, y1, x2, y2 = p.x, p.y, p.x, p.y
        amount = best.amount
        truncated = true
    end
    return amount, x1, y1, x2, y2, truncated
end

--- For every finite resource that `mined` does not hold, the nearest patch the
--- force has charted within SEARCH_RADIUS tiles of `bounds` ({left, top,
--- right, bottom}), the box itself included (distance 0). One count per
--- resource to see whether it exists at all, then a search per ring.
local function unmined_patches(surface, force, bounds, mined)
    local pending = {}
    for name in pairs(finite_resources()) do
        if not mined[name] then
            pending[#pending + 1] = name
        end
    end
    table.sort(pending)
    local band = { { bounds[1] - SEARCH_RADIUS, bounds[2] - SEARCH_RADIUS },
        { bounds[3] + SEARCH_RADIUS, bounds[4] + SEARCH_RADIUS } }
    local out = {}
    for _, name in ipairs(pending) do
        local counted, n = pcall(function()
            return surface.count_entities_filtered({ area = band, name = name, type = "resource", limit = 1 })
        end)
        local best, best_distance
        if counted and n > 0 then
            best, best_distance = nearest_in(surface, force, name, bounds,
                { { { bounds[1], bounds[2] }, { bounds[3], bounds[4] } } })
            local inner = 0
            while not best and inner < SEARCH_RADIUS do
                local outer = math.min(inner + RING_WIDTH, SEARCH_RADIUS)
                best, best_distance = nearest_in(surface, force, name, bounds, ring_strips(bounds, inner, outer))
                if best and outer < SEARCH_RADIUS then
                    local farther = math.min(outer + RING_WIDTH, SEARCH_RADIUS)
                    local other, other_distance = nearest_in(surface, force, name, bounds,
                        ring_strips(bounds, outer, farther))
                    if other and other_distance < best_distance then
                        best, best_distance = other, other_distance
                    end
                end
                inner = outer
            end
        end
        if best then
            local amount, x1, y1, x2, y2, truncated = measure_patch(surface, name, best)
            out[#out + 1] = {
                resource = name,
                position = pos(best),
                distance = round(best_distance, 1),
                amount = round(amount, 0),
                truncated = truncated or nil,
                enemies = enemies_near(surface, force, x1, y1, x2, y2),
            }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- The blueprint of the area
---------------------------------------------------------------------------

--- The area as a blueprint string and the world tile its (0, 0) is, or nil.
local function area_blueprint(surface, force, area)
    local inventory = game.create_inventory(1)
    local text, origin
    local ok = pcall(function()
        inventory[1].set_stack({ name = "blueprint" })
        local placed = inventory[1].create_blueprint({
            surface = surface,
            force = force,
            area = area,
            include_entities = true,
            include_modules = true,
            include_station_names = true,
            include_trains = false,
            include_fuel = false,
        })
        if table_size(placed) == 0 then
            return
        end
        -- The blueprint centres itself on the grid; the entity each of its
        -- own records stands for says where that landed in the world.
        for _, record in pairs(inventory[1].get_blueprint_entities() or {}) do
            local entity = placed[record.entity_number]
            if entity and entity.valid then
                origin = {
                    round(entity.position.x - record.position.x, 2),
                    round(entity.position.y - record.position.y, 2),
                }
                break
            end
        end
        text = inventory[1].export_stack()
    end)
    inventory.destroy()
    if not ok then
        return nil
    end
    return text, origin
end

---------------------------------------------------------------------------
-- The run
---------------------------------------------------------------------------

local function sample(s)
    local names = s.status_names
    for _, record in pairs(s.watched) do
        local entity = record.entity
        if entity.valid then
            local status = names[entity.status] or "unknown"
            record.n = record.n + 1
            record.states[status] = (record.states[status] or 0) + 1
            if record.crafting then
                local current = recipe_name_of(entity)
                if current then
                    record.recipe = current
                end
                if WAITING_INPUT[status] then
                    for _, ingredient in pairs(short_ingredients(entity, record.recipe)) do
                        record.missing[ingredient] = (record.missing[ingredient] or 0) + 1
                    end
                end
            end
            if record.network and POWER_SHORT[status] then
                local net = s.networks[record.network]
                if net then net.short = net.short + 1 end
            end
            if record.network then
                local net = s.networks[record.network]
                if net then net.samples = net.samples + 1 end
            end
        end
    end
end

local function shares(counts_by_state, n)
    local out = {}
    for state, count in pairs(counts_by_state) do
        out[state] = round(count / n, 3)
    end
    if next(out) then
        return out
    end
    return nil
end

local function cleanup(s)
    script.on_nth_tick(SAMPLE_EVERY, nil)
    storage.survey = nil
end

local function finish(s)
    local ticks = game.tick - s.started
    local seconds = ticks / constants.ticks_per_second

    local machines = {}
    local miners = {}
    local labs = {}
    for _, record in pairs(s.watched) do
        local entity = record.entity
        if entity.valid and record.n > 0 then
            if record.lab then
                labs[#labs + 1] = {
                    unit = record.unit,
                    name = entity.name,
                    position = pos(entity),
                    states = shares(record.states, record.n),
                }
            elseif record.crafting then
                local crafted = read(entity, "products_finished") or 0
                machines[#machines + 1] = {
                    unit = record.unit,
                    name = entity.name,
                    position = pos(entity),
                    direction = entity.direction,
                    recipe = record.recipe,
                    crafting_speed = round(read(entity, "crafting_speed") or 1, 3),
                    states = shares(record.states, record.n),
                    missing = shares(record.missing, record.n),
                    crafts_per_s = round((crafted - record.crafted) / seconds, 4),
                }
            else
                miners[#miners + 1] = {
                    unit = record.unit,
                    name = entity.name,
                    position = pos(entity),
                    resource = record.resource,
                    field = record.field,
                    states = shares(record.states, record.n),
                    amount_left = record.amount_left,
                    infinite = record.infinite,
                }
            end
        end
    end
    table.sort(machines, function(a, b) return a.unit < b.unit end)
    table.sort(miners, function(a, b) return a.unit < b.unit end)
    table.sort(labs, function(a, b) return a.unit < b.unit end)

    local research
    pcall(function()
        local current = s.force.current_research
        research = current and current.name or nil
    end)

    local flows = flows_between(production_now(s), s.production, seconds)

    local power = {}
    for id, net in pairs(s.networks) do
        local made, used
        if net.stats and net.stats.valid then
            local now = counts(net.stats, true)
            made = (sum(now.made) - net.made) / seconds
            used = (sum(now.used) - net.used) / seconds
        end
        if made then
            power[#power + 1] = {
                network = id,
                made_w = round(made, 1),
                used_w = round(used, 1),
                satisfaction = net.samples > 0 and round(1 - net.short / net.samples, 3) or 1,
                machines = net.machines,
            }
        end
    end
    table.sort(power, function(a, b) return a.network < b.network end)

    local blueprint, origin = area_blueprint(s.surface, s.force, s.area)
    -- The string and the world tile of its (0, 0) go together: a string with an
    -- unknown origin would put every position off by an unknown shift.
    if blueprint and not origin then
        blueprint = nil
    end

    local payload = {
        exported_by = "factorio-forge-companion",
        kind = "survey",
        game_version = read(helpers, "game_version") or (script.active_mods and script.active_mods["base"]) or nil,
        tick = game.tick,
        force = s.force.name,
        surface = s.surface.name,
        area = s.asked_area and {
            { s.asked_area.left_top.x, s.asked_area.left_top.y },
            { s.asked_area.right_bottom.x, s.asked_area.right_bottom.y },
        } or nil,
        bounds = { { s.area.left_top.x, s.area.left_top.y }, { s.area.right_bottom.x, s.area.right_bottom.y } },
        window_s = round(seconds, 2),
        machines = machines,
        miners = miners,
        labs = labs,
        research = research,
        unmined = s.unmined,
        fields = s.fields,
        flows = flows,
        power = power,
        blueprint = blueprint,
        blueprint_origin = origin,
    }
    -- JSON has no empty object: an empty list would be read as the wrong kind.
    if #machines == 0 then payload.machines = nil end
    if #miners == 0 then payload.miners = nil end
    if #labs == 0 then payload.labs = nil end
    if not s.unmined or #s.unmined == 0 then payload.unmined = nil end
    if #s.fields == 0 then payload.fields = nil end
    if #power == 0 then payload.power = nil end
    if not next(flows) then payload.flows = nil end

    helpers.write_file(FILE, helpers.table_to_json(payload), false)
    announce(s, string.format("Forge: survey written to %s (%d machines, %d drills, %d patches, %d power networks).",
        FILE, #machines, #miners, #s.fields, #power))
    cleanup(s)
end

function M.on_tick()
    local s = storage.survey
    if not s then
        script.on_nth_tick(SAMPLE_EVERY, nil)
        return
    end
    local ok, err = pcall(function()
        sample(s)
        if game.tick - s.started >= s.window_ticks then
            finish(s)
        end
    end)
    if not ok then
        write_failure(tostring(err))
        announce(s, "Forge: the survey failed: " .. tostring(err))
        cleanup(s)
    end
end

--- Everything that is read once at the start: what is watched, the patches
--- under the drills, the production totals.
local function begin(s)
    local surface, force, area = s.surface, s.force, s.area
    s.status_names = status_names()
    s.watched = {}
    s.networks = {}

    local function network_of(entity)
        local id = electric_network(entity)
        if id then
            local net = s.networks[id]
            if not net then
                net = { machines = 0, short = 0, samples = 0, made = 0, used = 0 }
                s.networks[id] = net
            end
            net.machines = net.machines + 1
            net.probe = net.probe or entity
        end
        return id
    end

    local crafting_count = 0
    for _, entity in pairs(surface.find_entities_filtered({ area = area, force = force, type = crafting_types() })) do
        if entity.unit_number then
            s.watched[entity.unit_number] = {
                entity = entity, unit = entity.unit_number, crafting = true,
                n = 0, states = {}, missing = {}, recipe = recipe_name_of(entity),
                crafted = read(entity, "products_finished") or 0,
                network = network_of(entity),
            }
            crafting_count = crafting_count + 1
        end
    end
    -- Labs are watched like machines (the share of the window in each status)
    -- but kept apart: they craft nothing.
    for _, entity in pairs(surface.find_entities_filtered({ area = area, force = force, type = "lab" })) do
        if entity.unit_number then
            s.watched[entity.unit_number] = {
                entity = entity, unit = entity.unit_number, lab = true, crafting = false,
                n = 0, states = {}, missing = {},
            }
        end
    end

    local drills = {}
    for _, entity in pairs(surface.find_entities_filtered({ area = area, force = force, type = "mining-drill" })) do
        if entity.unit_number then
            local under = resources_under(surface, entity)
            local target = read(entity, "mining_target")
            local name = target and target.valid and target.name or nil
            if not name then
                -- An idle drill names nothing: take what lies most under it.
                local best = 0
                for resource_name, list in pairs(under) do
                    local total = 0
                    for _, resource in ipairs(list) do total = total + resource.amount end
                    if total > best then
                        best, name = total, resource_name
                    end
                end
            end
            local list = name and under[name] or {}
            -- An infinite resource (a geyser, a fissure) has a yield, not an
            -- amount that runs out: no amount_left, no patch.
            local infinite = list[1] ~= nil and read(list[1].prototype, "infinite_resource") == true
            local left = 0
            for _, resource in ipairs(list) do
                left = left + resource.amount
            end
            local record = {
                entity = entity, unit = entity.unit_number, crafting = false,
                n = 0, states = {}, missing = {}, resource = name,
                amount_left = (name and not infinite) and round(left, 0) or nil,
                infinite = infinite or nil,
                network = network_of(entity),
            }
            s.watched[entity.unit_number] = record
            drills[#drills + 1] = { entity = entity, name = (not infinite) and name or nil, under = list, record = record }
        end
    end
    s.crafting_count, s.drill_count = crafting_count, #drills

    s.fields = build_fields(surface, force, drills, 1)
    for _, drill in ipairs(drills) do
        drill.record.field = drill.field
    end

    -- Resources no surveyed drill mines: where the nearest patch lies. Read once.
    local mined = {}
    for _, drill in ipairs(drills) do
        if drill.record.resource then
            mined[drill.record.resource] = true
        end
    end
    s.unmined = unmined_patches(surface, force, {
        area.left_top.x, area.left_top.y, area.right_bottom.x, area.right_bottom.y }, mined)

    -- A pole of a network is the best place to read its statistics from; a
    -- machine of the network will do when no pole stands in the area.
    pcall(function()
        for _, pole in pairs(surface.find_entities_filtered({ area = area, force = force, type = "electric-pole" })) do
            local id = electric_network(pole)
            local net = id and s.networks[id]
            if net and not net.pole then
                net.pole = pole
                net.probe = pole
            end
        end
    end)
    for _, net in pairs(s.networks) do
        local stats = net.probe and read(net.probe, "electric_network_statistics")
        if stats then
            net.stats = stats
            local now = counts(stats, true)
            net.made, net.used = sum(now.made), sum(now.used)
        end
    end

    s.production = production_now(s)
end

--- `/forge-survey [seconds] [surface=<name>] [area=x1,y1,x2,y2]`
function M.start(player, text)
    if storage.survey then
        say(player, "Forge: a survey is already running.")
        return
    end
    local options, problem = parse(text)
    if not options then
        say(player, { "forge.survey-usage" })
        say(player, "Forge: " .. problem)
        write_failure(problem)
        return
    end
    local surface = options.surface and game.get_surface(options.surface) or (not options.surface and player and player.surface) or nil
    if not surface then
        local reason = options.surface and ("no surface named " .. options.surface)
            or "no player to take a surface from: add surface=<name>"
        say(player, "Forge: " .. reason)
        write_failure(reason)
        return
    end
    local force = player and player.force or game.forces["player"]
    local area = options.area or default_area(surface, force)
    if not area then
        local reason = "the force has nothing on surface " .. surface.name
        say(player, "Forge: " .. reason)
        write_failure(reason)
        return
    end

    -- A file from an earlier run must not be taken for this one's answer.
    pcall(function() helpers.remove_path(FILE) end)

    local s = {
        surface = surface,
        force = force,
        area = area,
        asked_area = options.area,
        player_index = player and player.index or nil,
        started = game.tick,
        window_ticks = math.floor(options.seconds * constants.ticks_per_second),
    }
    local ok, err = pcall(begin, s)
    if not ok then
        write_failure(tostring(err))
        say(player, "Forge: could not start the survey: " .. tostring(err))
        return
    end
    storage.survey = s
    script.on_nth_tick(SAMPLE_EVERY, M.on_tick)
    local started = string.format("Forge: surveying %s for %d seconds: %d machines, %d drills.",
        surface.name, options.seconds, s.crafting_count, s.drill_count)
    log(started)
    say(player, started)
end

--- A saved game that was loaded in the middle of a survey carries on with it.
function M.on_load()
    if storage.survey then
        script.on_nth_tick(SAMPLE_EVERY, M.on_tick)
    end
end

return M
