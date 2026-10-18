# Factorio Forge Companion

A small Factorio mod that exports the things about a save which can only be
known from inside the running game.

[Русская версия](README.ru.md)

Companion to [factorio-forge](https://github.com/Fatoom333/factorio-forge), and
useful on its own if you want any of the four things below.

> **Status: 0.7.0.** Every command and the window have been exercised in real
> saves with large mod sets, and the 0.7.0 export has been run in one. What
> changed in each version is in [changelog.txt](changelog.txt), which the game
> also shows on the mod's Changelog tab.

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

Since 0.7.0 it also writes `bonuses`, the sums the in-game bonus screen shows,
read from the force rather than added up from technologies (some come from
elsewhere — the bulk inserter technology itself raises bulk inserter capacity):

- `force`: inserter and bulk inserter capacity, belt stack size, mining
  productivity, lab speed and productivity, robot speed, storage and battery,
  and the other force-wide bonuses, by their Lua API names;
- `recipe_productivity`: per-recipe productivity from research, where non-zero;
- `ammo_damage`, `gun_speed`, `turret_attack`: combat modifiers, where non-zero.

A bonus the running game version does not have is left out rather than failing
the export.

### The region selector, and `/forge-region <x1> <y1> <x2> <y2> [name]`

Exports a rectangle of the map as a blueprint string, written to
`blueprints/<name>.txt`.

The rectangle is usually easier dragged than typed. A shortcut on the toolbar
hands over a selection tool; drag it over the city block and the export
happens, amber border while you drag so it is not mistaken for a blueprint
selection. Dragging with Alt held leaves the tiles out, for when only the
machinery is wanted.

The command remains, and is the form a script would call, or the one to use
when the area is known but not on screen.

The game builds the blueprint, so the result is exactly what its own export
button would have given you.

Beside it goes `blueprints/<name>-underground.json`: every underground belt and
pipe in the area with the partner the game itself names. Which end of a run
pairs with which can only be inferred from outside, and that inference was
wrong twice before this file existed.

### `/forge-verify <blueprint string>`

Pastes a blueprint onto a scratch surface and reports how many entities
actually placed, and what failed.

The entities are really built, not ghosted. A ghost appears for anything a
blueprint mentions whether or not it could stand there, so only building tells
you what "will this place" means. The two ways of failing are reported apart: a
prototype that never became a ghost is one this mod set does not have, while
one that could not be built had nowhere to go.

The strongest check available, because the judge is the game rather than a
model of it: whatever will not place, does not place here either.

### `/forge-circuit <ticks> <blueprint string>`

Builds a circuit on the scratch surface, runs it for the given number of ticks,
and records every circuit network, one frame per tick, to `circuit-run.json`.

Signals live in a network rather than in an entity — a wire is shared — so the
wiring is written down once, saying which connector of which entity sits on
which network, and the frames then carry only the networks themselves.

Combinator behaviour lives in the engine rather than in the game's data, so
anything outside can only model it — and a model is a guess until something
checks it. This produces the something.

Per tick matters: one tick of delay per combinator is the basis of every
counter, clock and latch, so a summary that loses tick boundaries loses the
thing being studied.

The game is sped up while a run is in progress and returned to normal
afterwards — a five minute timer is eighteen thousand ticks, and waiting five
real minutes for it would be absurd. How far it is sped up is a mod setting,
*Circuit run speed*, because the right answer depends on where the run
happens.

A run costs the world exactly the ticks it asks for, whatever speed they pass
at — that is unavoidable, since the circuit only computes if the ticks really
happen. What speed decides is whether you are there for them: at sixty, five
minutes of game time passes in about five seconds, and a base under attack goes
unattended through all of it. Runs longer than ten seconds of game time
therefore say what they will cost and start nothing until the same command is
given again. The warning also writes an autosave, named `_autosave-forge`, so
there is a state to go back to; the name is not one the game's own rotation
uses, so nothing of yours is overwritten. It is written before anything is
built, so loading it puts you back where you were rather than into the middle
of a run.

Every entity is held at full charge for the duration. Combinators are
electrical devices, and an unpowered one does not compute, so a run on a
surface with no power network would otherwise record the right number of frames
with nothing happening in them. This is deliberate: the recording answers what
the logic does, not whether your power holds up.

### `/forge-measure <spec json>`

Builds a blueprint on an empty surface of its own, runs it for a while, and
writes `measure.json`: what the build really makes, not what its machines could.
`/forge-verify` asks whether a blueprint places; this asks what it does.

The command takes the spec as its text (a mod cannot read a file; the runner
sends one, see below):

```json
{"blueprint": "<string>", "surface": "vulcanus",
 "sources": [{"at": [x, y], "direction": 4, "items": ["iron-plate", "copper-cable"], "rate": 2.0},
             {"at": [x, y], "fluid": "water", "rate": 50}],
 "outputs": [{"at": [x, y], "item": "advanced-circuit"}],
 "targets": [{"item": "advanced-circuit", "rate": 1.0}],
 "warmup_s": 60, "measure_s": 120}
```

`at` is a tile in the blueprint's own coordinates (the ones the factorio-forge
plan and report use). Optional: `speed` (game speed during the run, up to 100),
`direction` on an output (the way a belt the run has to add flows),
`temperature` on a fluid source, `id` anywhere. `targets` are only passed
through for the reader of the result.

What the run does, and what it uses:

- **Surface.** A new surface with lab tiles and frozen daylight, given the
  surface properties (pressure, gravity, ...) of the planet named in
  `surface`. The planet is looked up as a prototype and nothing is hardcoded; a
  name nobody has gives the properties' defaults, and the file says so. A recipe
  whose surface conditions fail there is dropped by the paste, as in a real
  game: the machine then reports `no_recipe`.
- **Anchor.** The game centres a blueprint on the spot it is pasted at, so the
  shift between the blueprint's coordinates and the surface's is found by
  matching the stack's entities against the ones that stand (`anchor` in the
  file, with how many matched); sources and outputs are then placed by tile.
- **Power.** The mod's own `forge-power-source` (an `electric-energy-interface`,
  one gigawatt) and invisible poles over the whole build.
- **Supply.** Each belt source puts items on the belt at its tile by script: the
  first item on the left lane, the second (or the same) on the right, `rate`
  items per second over both lanes, as in a plan's `sources`; no rate means as
  fast as the belt takes. If the belt has no room the item waits, and
  `fed_rate` in the file shows what actually went in. A fluid source is an
  `infinity-pipe` on the tile; its rate is not limited. If there is no belt at a
  source's tile, one is added.
- **Sinks.** At each output the belt is emptied every tick and what was taken is
  counted by item (`outputs[].delivered`, per second). If there is no belt at an
  output's tile, one is added.
- **Window.** `warmup_s` seconds, then `measure_s` seconds counted. Production
  and consumption per second (`produced`, `consumed`, and the `fluids_` pair) are
  the force's production statistics for the measuring surface between the start
  and the end of the window. Every crafting machine's status is sampled every
  five ticks: `machines[].shares` is the share of samples working, waiting for
  input (with the ingredient it lacked in `missing`), blocked on a full output,
  without power, without fuel, or other. `final_status` counts the statuses of
  everything else at the end (an inserter without power shows there).
- **After.** The surface is deleted, game speed and the recipes the run had to
  unlock are put back; nothing of it stays in the save.

An error anywhere is written as `{"ok": false, "error": ...}` instead of
stopping a headless server.

### `/forge-clean`

Deletes the scratch surface, in case a run left one behind, stops a circuit
run that is still going, and puts back a game speed one of them raised.

Stopping writes nothing: a recording abandoned halfway is not a shorter
recording, it is a misleading one.

The two commands above delete it themselves when they finish, so this is only
needed if something was interrupted — a save taken in the middle of a circuit
run, say. It refuses while you are standing on the surface.

## The window

A button at the top left, in the row mods share, opens a small window with the
same work in it: export the environment, take the region selector, verify a
blueprint, record a circuit run, clean up.

The blueprint comes from the cursor rather than from a text field. Pasting
twenty thousand characters into a box is not something anyone does twice, and
the blueprint being looked at is already in hand. One out of the blueprint
library counts: that is a record rather than an item, and both are read.

A run long enough to matter is asked about first, with the same figures the
console gives — the ticks, the game time, the speed — and the order is confirm,
save, then speed: the autosave is written a tick before the run begins, so it
holds the state before any of it. Cancel does nothing at all.

The commands remain what a script calls, and the window is only another way to
reach them.

## Installing

Take `factorio-forge-companion_<version>.zip` from
[Releases](https://github.com/Fatoom333/factorio-forge-companion/releases), put
it in your Factorio `mods` folder without unpacking it, and enable the mod in
the in-game mod list. The file name matters: Factorio checks it against the
name inside, character for character.

## Building

```powershell
.\tools\build.ps1
```

Produces `dist/factorio-forge-companion_<version>.zip`, with `changelog.txt`
inside it. Copy that into your Factorio `mods` folder and enable it in the
in-game mod list.

`tools/lint.py` checks what can be checked without the game: Lua syntax,
functions defined twice, and locale keys matching between the two languages.
It needs `lupa`.

The script only builds; it does not install. It wraps the files in the folder
Factorio expects inside the archive — `<name>_<version>/` with `info.json` at
its root — which is the usual reason a hand-made mod zip refuses to load.

> If you are developing on it, a directory junction from the mods folder to the
> working copy is the tidy approach and worth trying. It did not work on the
> machine this was written on: a junction pointing at another drive listed its
> entries but every file inside failed to open, so the game found the mod and
> could not read a line of it. Rebuilding the zip works regardless.

## Running without a window

`tools/headless-run.ps1` takes a fresh export (and, given a blueprint, checks
it by really building it) with no game window and no player, on a throwaway
copy of a save:

```powershell
.\tools\headless-run.ps1 -Save my-save.zip -Out out `
    -Blueprint line.txt   # a file holding one blueprint string; optional
```

It refuses to start while Factorio is running, builds a temporary folder with
its own `config.ini`, a copy of the save and a copy of only the mods the save was made with,
starts `factorio --start-server` there (game and RCON ports on 127.0.0.1, at
random numbers, RCON password made per run and never printed), runs
`/forge-export` and `/forge-verify` over RCON, copies `environment.json` and
`verify.json` to `-Out`, quits the server, deletes the temporary folder, and
checks that the real saves, `mod-list.json` and `mod-settings.dat` are
byte-identical to before. Nothing is written to the game's install folder or
its real data folder, and nothing is downloaded. One limit: the RCON password
travels on the server's command line (`config.ini` keys are ignored by
`--start-server`), so for the length of the run a process of the same Windows
user could read it; it is random per run and the port is loopback only.

`-DataDir` names the real data folder (default `%APPDATA%\Factorio`),
`-Factorio` the executable (found in the usual Steam places otherwise),
`-ModZip` a freshly built companion to use instead of the installed one.

**Which mods load.** The save's own set, not the player's `mod-list.json`: the
list can have mods enabled for something else, and a run that loads them no
longer matches the save's profile. The script asks factorio-forge for the mods
in the save's header (`factorio_forge.save`, run with `-ForgePython`, else
`$env:FACTORIO_FORGE_PYTHON`, else `python` or `py`) and writes the temporary
`mod-list.json` from them; built-in mods the save does not use are switched off.
Each mod is copied at the version the save names when that file is in the mods
folder, otherwise at the newest one there, and the run prints and writes
(`mods-used.txt` in `-Out`) which it used. The companion is always added, at
`-ModZip` if given. `-UseModList` takes the player's mod-list.json instead.

**Measuring.** `-Measure spec.json` runs `/forge-measure` on a spec file (see
above; the script sends it over RCON, since a mod cannot read files) and copies
`measure.json` to `-Out`. It needs the companion 0.8.0 or newer. The wait is
sized from the spec's warm-up, measured stretch and `speed`; at `speed` 10 a
60 + 120 second run takes about twenty seconds. factorio-forge writes the spec
from a plan (`factorio-forge measure spec`) and reads the answer back
(`factorio-forge measure result`).

What the commands need. `/forge-export` and `/forge-verify` run with no player
(from companion 0.7.1; in 0.7.0 `game.get_player(nil)` raised, and a headless
server stops on any error in a command). The script reads the version of the
mod it is about to use and stops with a message if it is older than 0.7.1: with
a 0.7.0 install, pass a fresh build with `-ModZip`. A refusal ("not a blueprint")
is sent back over RCON and ends the run at once. Exit codes: 0 done, 1 failed,
2 Factorio was already running (nothing was started). `/forge-region`, `/forge-circuit` and
`/forge-clean` need a player's surface and force, so at the console they now do
nothing rather than stop the server. One RCON packet carried a 59 KB blueprint
without trouble. On the Windows Steam build the process does not exit after
`/quit` (the game session closes and the log says so, then the process sits
idle); the script ends its own process by pid a few seconds after that.

## A note on scope

This mod mostly reads and writes files. `/forge-verify`, `/forge-circuit` and
`/forge-measure` work on a separate scratch surface created for the purpose,
never on the surface you are playing on.

`/forge-measure` does reach past that surface while it runs: it switches on, for
your force, the recipes the build uses if you have not unlocked them, and it can
change the game speed. Both are put back when the run ends, is stopped with
`/forge-clean`, or fails. In a game you care about, run it through
`tools/headless-run.ps1` on a copy of the save instead.

It does define two prototypes, and both exist only to power that scratch
surface: an electric pole with the largest supply area the engine allows, and
an energy source to feed it. Combinators have no energy buffer and draw from a
network every tick, so a circuit on no network computes nothing.

Both are invisible and collide with nothing, so a pole can stand on the same
tile as a combinator and takes no space in what is being looked at. That is
what lets the coverage be laid down over the blueprint whatever the blueprint
contains, rather than threaded between its entities -- which is the approach
that fails exactly when a circuit is densely packed. Neither prototype has an
item, and neither can be selected, blueprinted or deconstructed.

That surface is deleted again as soon as the command has its answer. Clearing
the entities off it would not be enough: ground stays in a save once generated,
and would grow with the largest blueprint ever checked, so the surface goes
rather than accumulates.

## What was on the roadmap

All of it is done: an area dragged instead of coordinates typed, a window in
place of four console commands, and a game speed that comes back after a run
was interrupted. Since then 0.7.0 has added the bonuses to the export, because
factorio-forge needed them and could not read them on its own.
[ROADMAP.md](ROADMAP.md) keeps the record and what it cost.

## Licence

MIT. Factorio is a trademark of Wube Software; this is an unofficial community
mod.
