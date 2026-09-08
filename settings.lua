--- Settings a player can change without touching the mod.
---
--- Speed is here rather than fixed in the code because the right value depends
--- on where the run happens. On a scratch save sixty is simply faster; on a
--- live base it means the factory lives through the whole run in a few real
--- seconds, with no chance to react to anything that goes wrong. Somebody
--- playing on their own base may well want five, and that is their call to
--- make, not this mod's.

data:extend({
    {
        type = "int-setting",
        name = "forge-circuit-speed",
        setting_type = "runtime-global",
        default_value = 60,
        minimum_value = 1,
        maximum_value = 1000,
        order = "a",
    },
})
