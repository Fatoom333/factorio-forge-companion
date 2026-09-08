--- Numbers that both the data stage and the running game need to agree on.
---
--- Required because they are ours: the pole is defined by this mod, so its
--- size is not something to ask the game about at runtime. Reading it back
--- from the prototype was tried and returned nothing, which quietly collapsed
--- the pole spacing to one tile and covered a small blueprint with forty-nine
--- poles. A single written-down number cannot disagree with itself.

return {
    -- 64 is the largest supply area the engine accepts. One pole covers 128
    -- tiles across, which is most circuits in a single placement.
    pole_supply = 64,
    pole_wire = 64,

    -- Far more than any circuit can draw: a combinator costs a kilowatt, and
    -- the point is that power is never the reason something did not run.
    source_production = 1000000000,

    -- Above this a run is worth stopping to think about: ten seconds of game
    -- time is a moment on a scratch save and a real absence on a live base.
    confirm_above_ticks = 600,

    -- How long a warning stands before the same command counts as a fresh
    -- request rather than a confirmation. One minute of game time.
    confirmation_lasts = 3600,
}
