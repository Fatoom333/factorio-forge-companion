# Factorio Forge Companion

A small Factorio mod that exports the things about a save which can only be
known from inside the running game.

[Русская версия](README.ru.md)

Companion to [factorio-forge](https://github.com/Fatoom333/factorio-forge), and
useful on its own if you want any of the four things below.

> **Status: early.** Written, not yet exercised in a real game. Expect rough
> edges until it has been.

## Why it exists

A save file's own format is internal, version-specific and not worth parsing.
The game's data files describe what *exists* but say nothing about *state* —
what has been researched, what a startup setting was set to, what a circuit
actually does when it runs.

Rather than model any of that from outside, this asks the game.

## What it does

Everything is written to `script-output/factorio-forge/` in your Factorio user
directory.

### `/forge-export`

Writes `environment.json`: the exact mod set with versions, every startup mod
setting, which technologies are researched and which recipes are actually
unlocked.

The mod list can be read from a save's header from outside. The **startup
settings cannot**, and they change recipes — how long an underground pipe runs,
whether a mod's loaders exist at all. Extracting game data without them is
subtly wrong in a way nothing detects, which is the main reason this command
exists.

### `/forge-region <x1> <y1> <x2> <y2> [name]`

Exports a rectangle of the map as a blueprint string, written to
`blueprints/<name>.txt`.

The game builds the blueprint, so the result is exactly what its own export
button would have given you. This turns "show me your city block" into a
command rather than a manual selection.

### `/forge-verify <blueprint string>`

Pastes a blueprint onto a scratch surface and reports how many entities
actually placed, and which prototypes did not.

The strongest check available, because the judge is the game rather than a
model of it: whatever will not place, does not place here either.

### `/forge-circuit <ticks> <blueprint string>`

Builds a circuit on the scratch surface, runs it for the given number of ticks,
and records every circuit network on every wired entity, one frame per tick, to
`circuit-run.json`.

Combinator behaviour lives in the engine rather than in the game's data, so
anything outside can only model it — and a model is a guess until something
checks it. This produces the something.

Per tick matters: one tick of delay per combinator is the basis of every
counter, clock and latch, so a summary that loses tick boundaries loses the
thing being studied.

The game is sped up while a run is in progress and returned to normal
afterwards. A five minute timer is eighteen thousand ticks, and waiting five
real minutes for it would be absurd.

## Installing

Copy or link this folder into your Factorio `mods` directory. On Windows:

```
mklink /J "%APPDATA%\Factorio\mods\factorio-forge-companion" "<this folder>"
```

Then enable it in the mod list and restart the game.

## A note on scope

This mod only reads and writes files. It adds no prototypes, changes no
recipes, and touches nothing in your world — `/forge-verify` and
`/forge-circuit` work on a separate scratch surface created for the purpose,
never on the surface you are playing on.

## Licence

MIT. Factorio is a trademark of Wube Software; this is an unofficial community
mod.
