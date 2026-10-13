# Mod portal page — draft

Prepared for mods.factorio.com. Nothing has been uploaded.

## Fields

| Field | Value |
|---|---|
| Internal name | `factorio-forge-companion` (from info.json; cannot be changed after upload) |
| Title | Factorio Forge Companion |
| Category | Utilities |
| Tags | Blueprints, Circuit network |
| Licence | MIT |
| Source URL | https://github.com/Fatoom333/factorio-forge-companion |
| Homepage | https://github.com/Fatoom333/factorio-forge-companion (already in info.json) |
| Factorio version | 2.0 |
| File | `factorio-forge-companion_0.7.0.zip` from the v0.7.0 GitHub release |

The changelog is taken from `changelog.txt` inside the zip; nothing to fill in by hand.

## Summary (one line)

Exports what only the running game knows about a save — exact mods and startup settings, research and bonuses, regions as blueprints, and circuits recorded tick by tick.

## Description

```markdown
A small mod that exports the things about a save which can only be known from inside the running game. Companion to [factorio-forge](https://github.com/Fatoom333/factorio-forge), and useful on its own.

Everything is written to `script-output/factorio-forge/` in your Factorio user directory.

## Why

A save file's own format is internal and version-specific. The game's data files describe what *exists*, but say nothing about *state*: what has been researched, what a startup setting was set to, what a circuit actually does when it runs. Rather than model any of that from outside, this mod asks the game.

## What it does

- **`/forge-export`** — writes `environment.json`: the exact mod set with versions, every startup setting, what is researched and which recipes are unlocked, and the bonuses research has added up to (inserter capacity, belt stack size, mining and lab productivity, robot bonuses, per-recipe productivity, combat modifiers). Startup settings cannot be read from outside a save, and they change recipes.
- **Region selector**, or **`/forge-region x1 y1 x2 y2 [name]`** — drag a rectangle and it is exported as a blueprint string, built by the game itself. Beside it goes a file naming the partner of every underground belt and pipe inside, as the engine sees it.
- **`/forge-verify <blueprint>`** — builds the blueprint on a scratch surface for real, not as ghosts, and reports what placed and what failed: a prototype this mod set does not have, apart from one that had nowhere to go.
- **`/forge-circuit <ticks> <blueprint>`** — runs a circuit on the scratch surface and records every circuit network, one frame per tick. Combinator behaviour lives in the engine; this is what a model of it can be checked against.
- **`/forge-clean`** — stops a run, restores the game speed, removes the scratch surface.
- **A window** at the top left with all of the above, reading the blueprint from your cursor — inventory or blueprint library.

## Care taken with your save

- Nothing in your world is touched. Verification and circuit runs happen on a separate scratch surface, which is deleted afterwards rather than emptied, so no generated ground stays in the save.
- A long circuit run says what it will cost in game time and waits for confirmation. It writes an autosave named `_autosave-forge` first — a name the game's own rotation never uses — so there is a state to go back to.
- Run speed is a mod setting: sixty on a scratch save, lower on a live base where you may want to stay able to react. The speed comes back even if a run was interrupted.
- The mod adds two invisible prototypes, an electric pole and an energy source, used only to power the scratch surface. They have no items and cannot be selected, blueprinted or deconstructed.

## Languages

English, Russian.

Source, issues and the full documentation: [GitHub](https://github.com/Fatoom333/factorio-forge-companion). Factorio is a trademark of Wube Software; this is an unofficial community mod.
```

## Still missing before upload

- **thumbnail.png is missing.** The portal shows a placeholder without it. Needs a 144×144 PNG in the mod root, added to the `$contents` list in `tools/build.ps1` so it goes into the zip, and uploaded on the portal page as well.
- **Gallery images:** none yet. A screenshot of the window and one of the region selector would help.
- **Name check:** that `factorio-forge-companion` is still free on the portal has not been checked.
- Upload is done by hand by the author, logged in to mods.factorio.com.
