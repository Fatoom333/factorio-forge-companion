# The road to 1.0.0, and what it cost

Everything the first roadmap asked for is done. Kept as a record, because each
item turned out to be about something other than what it looked like.

[Русская версия](ROADMAP.ru.md)

## Select an area instead of typing its corners — 0.3.0

`/forge-region -100 -100 100 100` asked a player to know four numbers about a
place they were standing in. A selection tool now drags the rectangle instead,
and the command stays for scripts and for areas that are known but not visible.

The border is amber rather than the blueprint's blue: while dragging, the colour
is the only thing that says which tool is in hand.

## Restore the game speed after an interrupted run — 0.4.0

A recording raised the speed and lowered it again at the end, so a run that
never reached its end left the speed raised, with the value to restore sitting
inside the run that never finished. Both speeds are kept outside the run now,
and put back on the first tick after a load, or by `/forge-clean`.

Along the way it turned out there was no way to stop a run at all: eighteen
thousand ticks asked for by mistake had to be waited out. `/forge-clean` stops
one now, and writes nothing, because a recording abandoned halfway is not a
shorter recording but a misleading one.

## A small window — 0.5.0

Four commands with their own argument orders is a poor way to reach something
used often. A button in the row mods share at the top left opens a window with
the same work in it.

The part worth keeping from this one: a blueprint is read from the cursor, and
"in the cursor" is two different things. An inventory blueprint is an item; a
library blueprint is a record, which is not an item and has neither
`export_stack` nor `label`. Its entities can still be read, and the entities
are the blueprint.

## Nothing is planned beyond this

The commands and the window cover what the tool needs from inside the game. New
work here should come from something factorio-forge cannot answer on its own,
rather than from tidiness.
