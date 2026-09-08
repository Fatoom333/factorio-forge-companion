--- Factorio Forge Companion
---
--- Exports what only the running game knows. A save file's own format is
--- internal and not worth parsing, and the data stage cannot answer questions
--- about state -- what has been researched, what a circuit actually does. So
--- the game answers them itself, and writes the answers where a tool outside
--- can read them.
---
--- Everything lands in `script-output/factorio-forge/`.

local circuit = require("circuit")
local constants = require("constants")
local gui = require("gui")
local scratch = require("scratch")

local OUTPUT = "factorio-forge/"

--- Write a table as JSON, and tell the player where it went.
---@param name string file name within the output folder
---@param payload table
---@param player LuaPlayer|nil whom to tell
local function write(name, payload, player)
    local path = OUTPUT .. name
    helpers.write_file(path, helpers.table_to_json(payload), false)
    if player then
        player.print({ "forge.written", path })
    end
    return path
end

--- Everything the data stage cannot tell you, because it is state rather than
--- definition: which mods are loaded at which versions, what their startup
--- settings were set to, and what this force has researched.
---
--- The mod list is also readable from a save's header from outside, but the
--- settings are not, and they change recipes. That gap is why this exists.
local function export_environment(player)
    local mods = {}
    for name, version in pairs(script.active_mods) do
        mods[name] = version
    end

    local startup = {}
    for name, entry in pairs(settings.startup) do
        startup[name] = entry.value
    end

    local force = player and player.force or game.forces["player"]

    local researched = {}
    local pending = {}
    for name, technology in pairs(force.technologies) do
        if technology.researched then
            researched[#researched + 1] = name
        elseif technology.enabled then
            pending[#pending + 1] = name
        end
    end
    table.sort(researched)
    table.sort(pending)

    local recipes_enabled = {}
    for name, recipe in pairs(force.recipes) do
        if recipe.enabled and not recipe.hidden then
            recipes_enabled[#recipes_enabled + 1] = name
        end
    end
    table.sort(recipes_enabled)

    return write("environment.json", {
        exported_by = "factorio-forge-companion",
        game_version = helpers.game_version or "unknown",
        tick = game.tick,
        force = force.name,
        mods = mods,
        startup_settings = startup,
        researched = researched,
        available_to_research = pending,
        recipes_enabled = recipes_enabled,
        counts = {
            mods = table_size(mods),
            researched = #researched,
            recipes_enabled = #recipes_enabled,
        },
    }, player)
end

--- Turn a rectangle of the world into a blueprint string.
---
--- This is what makes "show me your city block" a button press rather than a
--- manual selection, and it is exact: the game builds the blueprint, so the
--- result is what the game would have given you.
--- Gather entities out of whatever shape `neighbours` came back as.
---
--- It is not one shape. An underground belt hands back the single entity it
--- pairs with; a pipe hands back a list per fluid connection, so a list of
--- lists; and either can hand back nothing. Walking it as a plain table is
--- what made the first attempt at this crash: the belt's answer is a
--- LuaEntity, which is userdata rather than a table.
local function collect_entities(value, out)
    if value == nil then
        return out
    end
    if type(value) == "table" then
        for _, item in pairs(value) do
            collect_entities(item, out)
        end
    elseif type(value) == "userdata" and value.valid then
        out[#out + 1] = {
            name = value.name,
            x = value.position.x,
            y = value.position.y,
        }
    end
    return out
end

--- What the game itself says about the underground runs inside an area.
---
--- An underground belt or pipe knows its own partner, and the game will say
--- which it is. Everything outside can only infer it from directions and
--- distances, and that inference is exactly what went wrong twice: first
--- reading the run as following the entity's facing, then arguing about a pipe
--- that caps a row. There is no need to argue with something that can be
--- asked.
---
--- Written beside the blueprint, so a checker can be held against the truth
--- rather than against another reading of the same picture.
local function export_underground_pairs(player, area, name)
    local runs = {}
    for _, entity in pairs(player.surface.find_entities_filtered({
        area = area,
        type = { "underground-belt", "pipe-to-ground" },
    })) do
        local partners = {}
        collect_entities(entity.neighbours, partners)
        runs[#runs + 1] = {
            name = entity.name,
            type = entity.type,
            x = entity.position.x,
            y = entity.position.y,
            direction = entity.direction,
            io_type = entity.type == "underground-belt" and entity.belt_to_ground_type or nil,
            partners = partners,
        }
    end

    local path = OUTPUT .. "blueprints/" .. name .. "-underground.json"
    helpers.write_file(path, helpers.table_to_json({
        exported_by = "factorio-forge-companion",
        note = "Each underground entity in the exported area, with the partner "
            .. "the game itself reports. Directions are the entity's own.",
        runs = runs,
    }), false)
    return #runs
end

local function export_region(player, area, name, with_tiles)
    local inventory = game.create_inventory(1)
    inventory[1].set_stack({ name = "blueprint" })

    local placed = inventory[1].create_blueprint({
        surface = player.surface,
        force = player.force,
        area = area,
        always_include_tiles = with_tiles,
        include_entities = true,
        include_modules = true,
        include_station_names = true,
        include_trains = false,
        include_fuel = false,
    })

    if table_size(placed) == 0 then
        inventory.destroy()
        player.print({ "forge.region-empty" })
        return nil
    end

    inventory[1].label = name
    local text = inventory[1].export_stack()
    inventory.destroy()

    local file = OUTPUT .. "blueprints/" .. name .. ".txt"
    helpers.write_file(file, text, false)
    export_underground_pairs(player, area, name)
    player.print({ "forge.region-written", table_size(placed), file })
    return text
end

--- Paste a blueprint onto a scratch surface and report what actually landed.
---
--- The strongest check there is, because the judge is the game rather than a
--- model of it: anything that will not place, does not place here either.
local function verify_blueprint(player, text)
    local inventory = game.create_inventory(1)
    inventory[1].import_stack(text)
    if not inventory[1].is_blueprint_setup() then
        inventory.destroy()
        player.print({ "forge.not-a-blueprint" })
        return
    end

    local surface = scratch.surface()
    scratch.clear(surface)

    -- The ground has to exist before anything can be built on it, and the
    -- chunks of a freshly created surface do not exist until asked for.
    local origin = { x = 0, y = 0 }
    scratch.prepare(surface, inventory[1].get_blueprint_entities(), origin)

    local ghosts = inventory[1].build_blueprint({
        surface = surface,
        force = player.force,
        position = origin,
        build_mode = defines.build_mode.forced,
    })

    -- Ghosts are not the answer to the question being asked. A ghost is placed
    -- for anything the blueprint mentions, whether or not the thing could
    -- stand there; only reviving one puts a real entity on the ground, and
    -- that is what "will this place" means. So each ghost is revived, and the
    -- two ways of failing are reported apart: a prototype the game would not
    -- even ghost is missing from the game, while one that ghosted and would
    -- not revive had nowhere to go.
    local built, refused = 0, {}
    for _, ghost in pairs(ghosts) do
        if ghost.valid then
            if ghost.name == "entity-ghost" then
                local name = ghost.ghost_name
                local _, revived = ghost.revive()
                if revived then
                    built = built + 1
                else
                    refused[name] = (refused[name] or 0) + 1
                end
            else
                built = built + 1
            end
        end
    end

    local entries = inventory[1].get_blueprint_entities()
    local wanted = #entries
    local report = {
        placed = built,
        expected = wanted,
        missing = {},
        refused = refused,
    }
    if #ghosts < wanted then
        -- Which prototypes never even became a ghost is more useful than how
        -- many: that is the mod set disagreeing with the blueprint.
        local seen = {}
        for _, entry in pairs(entries) do
            seen[entry.name] = (seen[entry.name] or 0) + 1
        end
        for _, ghost in pairs(ghosts) do
            local name = ghost.ghost_name or ghost.name
            seen[name] = (seen[name] or 0) - 1
        end
        for name, remaining in pairs(seen) do
            if remaining > 0 then
                report.missing[name] = remaining
            end
        end
    end

    inventory.destroy()
    write("verify.json", report, player)
    player.print({ "forge.verified", report.placed, report.expected })

    -- The answer has been read, so the surface has served its purpose and
    -- leaves nothing behind in the save.
    scratch.remove()
end

commands.add_command("forge-export", { "forge.cmd-export" }, function(event)
    local player = game.get_player(event.player_index)
    export_environment(player)
end)

commands.add_command("forge-region", { "forge.cmd-region" }, function(event)
    local player = game.get_player(event.player_index)
    local words = {}
    for word in string.gmatch(event.parameter or "", "%S+") do
        words[#words + 1] = word
    end
    if #words < 4 then
        player.print({ "forge.region-usage" })
        return
    end
    local x1, y1 = tonumber(words[1]), tonumber(words[2])
    local x2, y2 = tonumber(words[3]), tonumber(words[4])
    if not (x1 and y1 and x2 and y2) then
        player.print({ "forge.region-usage" })
        return
    end
    export_region(
        player,
        { { x1, y1 }, { x2, y2 } },
        words[5] or ("region-" .. game.tick),
        true
    )
end)

commands.add_command("forge-verify", { "forge.cmd-verify" }, function(event)
    local player = game.get_player(event.player_index)
    if not event.parameter or event.parameter == "" then
        player.print({ "forge.verify-usage" })
        return
    end
    verify_blueprint(player, event.parameter)
end)

--- A run costs the world the ticks it asks for, whatever speed they pass at,
--- and the player cannot step in while they do. Long runs therefore say what
--- they will cost and wait to be asked twice; the second command within the
--- minute is the confirmation.
local function confirmed(player, parameter, ticks)
    if ticks <= constants.confirm_above_ticks then
        return true
    end

    local pending = storage.pending_run
    if pending
        and pending.parameter == parameter
        and game.tick - pending.at <= constants.confirmation_lasts
    then
        storage.pending_run = nil
        return true
    end

    storage.pending_run = { parameter = parameter, at = game.tick }

    -- Written now, on the warning rather than on the confirmation, so that the
    -- saved state is the one before any of this: no scratch surface, no
    -- circuit built, normal speed. A save taken at the start of the run would
    -- restore into the middle of it.
    game.auto_save(constants.autosave_name)

    player.print({
        "forge.circuit-cost",
        ticks,
        string.format("%.1f", ticks / constants.ticks_per_second),
        settings.global["forge-circuit-speed"].value,
    })
    player.print({ "forge.circuit-confirm" })
    return false
end

commands.add_command("forge-circuit", { "forge.cmd-circuit" }, function(event)
    local player = game.get_player(event.player_index)
    local ticks, text = string.match(event.parameter or "", "^(%d+)%s+(.+)$")
    if not ticks then
        player.print({ "forge.circuit-usage" })
        return
    end
    if not confirmed(player, event.parameter, tonumber(ticks)) then
        return
    end
    circuit.start(player, text, tonumber(ticks))
end)

commands.add_command("forge-clean", { "forge.cmd-clean" }, function(event)
    local player = game.get_player(event.player_index)
    local aborted = circuit.abort()
    if aborted then
        player.print({ "forge.run-aborted", aborted })
    end

    local speed_restored = circuit.restore_speed()
    local status = scratch.remove()
    if speed_restored then
        player.print({ "forge.clean-speed" })
    end
    if status == "removed" then
        player.print({ "forge.cleaned" })
    elseif status == "occupied" then
        player.print({ "forge.clean-occupied" })
    else
        player.print({ "forge.clean-absent" })
    end
end)

--- Dragging the selection tool exports whatever rectangle was dragged.
---
--- The area is what is used, not the entities the game hands over with it: the
--- export asks the game to build a blueprint of the rectangle, which is what
--- its own export button would have given. Selecting normally takes the tiles
--- as well -- concrete and bricks are part of a city block -- and alt-select
--- leaves them out, for when only the machinery is wanted.
local function on_selection(event, with_tiles)
    if event.item ~= constants.selector then
        return
    end
    local player = game.get_player(event.player_index)
    export_region(player, event.area, "region-" .. game.tick, with_tiles)
end

script.on_event(defines.events.on_player_selected_area, function(event)
    on_selection(event, true)
end)

script.on_event(defines.events.on_player_alt_selected_area, function(event)
    on_selection(event, false)
end)

--- The window's buttons, bound to the same work the commands do.
---
--- Bound here rather than inside the window because this file owns the
--- actions; the window owns only how they are reached.
gui.actions = {
    export = export_environment,
    verify = verify_blueprint,
    circuit = function(player, text, ticks)
        circuit.start(player, text, ticks)
    end,
    clean = function(player)
        local aborted = circuit.abort()
        if aborted then
            player.print({ "forge.run-aborted", aborted })
        end
        if circuit.restore_speed() then
            player.print({ "forge.clean-speed" })
        end
        local status = scratch.remove()
        if status == "removed" then
            player.print({ "forge.cleaned" })
        elseif status == "occupied" then
            player.print({ "forge.clean-occupied" })
        else
            player.print({ "forge.clean-absent" })
        end
    end,
    selector = function(player)
        player.clear_cursor()
        player.cursor_stack.set_stack({ name = constants.selector })
    end,
}

script.on_event(defines.events.on_gui_click, gui.on_click)

-- The button has to exist for players who were already here when the mod
-- arrived, not only for ones who join afterwards.
local function give_everyone_the_button()
    for _, player in pairs(game.players) do
        gui.ensure_button(player)
    end
end

script.on_init(give_everyone_the_button)
script.on_configuration_changed(give_everyone_the_button)
script.on_event(defines.events.on_player_created, function(event)
    gui.ensure_button(game.get_player(event.player_index))
end)

-- The window says whether a blueprint is in hand, so it has to hear about the
-- cursor changing rather than showing a stale answer.
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
    gui.refresh(game.get_player(event.player_index))
end)

script.on_load(circuit.on_load)
