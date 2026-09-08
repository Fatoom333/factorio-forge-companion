# Towards 1.0.0

What this mod still owes, kept here rather than in a conversation.

[Русская версия](ROADMAP.ru.md)

## ~~Select an area instead of typing its corners~~ — done in 0.3.0

`/forge-region -100 -100 100 100 cityblock` asks the player to know four
numbers about a place they are standing in. A selection tool — the kind
Factorio's own planners use — would let them drag a rectangle over the city
block and be done, with the coordinates coming from the drag.

The command should stay. It is what a script or another tool would call, and it
is the only form that works when the area is known but not visible.

## ~~A small window~~ — done in 0.5.0

Four commands typed into a console, each with its own argument order, is a poor
way to reach a tool used often. A window with the four actions, the run length
for a circuit recording, and the last result would carry the same features at a
fraction of the effort to use.

Worth doing only after the commands themselves have settled, since a window
around a moving target is work done twice.

## ~~Restore the game speed after an interrupted run~~ — done in 0.4.0

A circuit run raises the game speed and lowers it again when it finishes. If the
game is closed in the middle, the speed stays raised in the save: the value to
restore lives in the run that never completed.

Restoring it on load whenever no run is active would close that, as would
lowering it in `/forge-clean`.
