--- Numbers that both the data stage and the running game need to agree on.
---
--- Required because they are ours: the pole is defined by this mod, so its
--- size is not something to ask the game about at runtime. Reading it back
--- from the prototype was tried and returned nothing, which quietly collapsed
--- the pole spacing to one tile and covered a small blueprint with forty-nine
--- poles. A single written-down number cannot disagree with itself.

local M = {}

-- Numbers the engine fixes, named here so the arithmetic that uses them reads
-- as what it means rather than as a bare figure. Neither is available through
-- the API: the game runs at sixty ticks a second and generates the map in
-- thirty-two tile chunks, and it always has.
M.ticks_per_second = 60
M.chunk_size = 32

-- The prototypes this mod defines, named in one place because two files need
-- to agree on them: data.lua declares them and the runtime places them.
M.pole = "forge-power-pole"
M.source = "forge-power-source"
M.scratch_surface = "forge-scratch"

-- The selection tool and the shortcut that hands it over. `/forge-region`
-- makes a player know four numbers about a place they are standing in; this
-- lets them drag a rectangle over it instead.
M.selector = "forge-region-selector"
M.selector_shortcut = "forge-give-region-selector"

-- How large the scratch surface is allowed to be. Chunks are only generated
-- where something is built, so this is a limit rather than a cost, and it is
-- wider than any blueprint a player can paste.
M.scratch_size = 2000

-- 64 is the largest supply area the engine accepts. One pole covers 128 tiles
-- across, which is most circuits in a single placement.
M.pole_supply = 64
M.pole_wire = 64

-- Far more than any circuit can draw: a combinator costs a kilowatt, and the
-- point is that power is never the reason something did not run.
M.source_production = 1000000000

-- Above this a run is worth stopping to think about: ten seconds of game time
-- is a moment on a scratch save and a real absence on a live base.
M.confirm_above_ticks = 10 * M.ticks_per_second

-- How long a warning stands before the same command counts as a fresh request
-- rather than a confirmation.
M.confirmation_lasts = 60 * M.ticks_per_second

-- How far from its intended spot a pole may be nudged to find room. Ours
-- collides with nothing, so this only matters if the prototype is ever given a
-- footprint; a pole a few tiles off still covers what it needs to.
M.placement_search = 3

-- The name handed to game.auto_save, which prefixes it with `_autosave`, giving
-- `_autosave-forge`. Deliberately not a number: the game's own rotation writes
-- `_autosave1` and up, so nothing of the player's -- their saves or their
-- autosaves -- is overwritten by this one.
M.autosave_name = "-forge"

return M
