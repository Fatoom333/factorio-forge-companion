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

Every entity is held at full charge for the duration. Combinators are
electrical devices, and an unpowered one does not compute, so a run on a
surface with no power network would otherwise record the right number of frames
with nothing happening in them. This is deliberate: the recording answers what
the logic does, not whether your power holds up.

### `/forge-clean`

Deletes the scratch surface, in case a run left one behind.

The two commands above delete it themselves when they finish, so this is only
needed if something was interrupted — a save taken in the middle of a circuit
run, say. It refuses while you are standing on the surface.

## Building

```powershell
.\tools\build.ps1
```

Produces `dist/factorio-forge-companion_<version>.zip`. Copy that into your
Factorio `mods` folder and enable it in the in-game mod list.

The script only builds; it does not install. It wraps the files in the folder
Factorio expects inside the archive — `<name>_<version>/` with `info.json` at
its root — which is the usual reason a hand-made mod zip refuses to load.

> If you are developing on it, a directory junction from the mods folder to the
> working copy is the tidy approach and worth trying. It did not work on the
> machine this was written on: a junction pointing at another drive listed its
> entries but every file inside failed to open, so the game found the mod and
> could not read a line of it. Rebuilding the zip works regardless.

## A note on scope

This mod only reads and writes files. It changes no recipes and touches
nothing in your world — `/forge-verify` and `/forge-circuit` work on a separate
scratch surface created for the purpose, never on the surface you are playing
on.

It does define two prototypes, and both exist only to power that scratch
surface: an electric pole with the largest supply area the engine allows, and
an energy source to feed it. Combinators have no energy buffer and draw from a
network every tick, so a circuit on no network computes nothing; powering it
with the game's own poles would mean threading a grid of them between the
blueprint's own entities, which fails exactly when the blueprint is dense.
Neither prototype has an item, so neither can be built, mined or held.

That surface is deleted again as soon as the command has its answer. Clearing
the entities off it would not be enough: ground stays in a save once generated,
and would grow with the largest blueprint ever checked, so the surface goes
rather than accumulates.

## Licence

MIT. Factorio is a trademark of Wube Software; this is an unofficial community
mod.
