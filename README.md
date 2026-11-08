# Roads of Azeroth

*by DinX* · WoW Forever (interface 16001)

A quest tracker with a smart quest route, a GPS with flight paths, a navigation arrow and the route on the world map. It used to be part of CasterKit (now **Casters of Azeroth**) and works on its own or together with **Casters of Azeroth** and **Scrum of Azeroth**.

## Features
- **Quest tracker**: a compact list with level colours, progress bars, turn-ins on top, quest item buttons, and folding per quest. You can resize it and it scales with the font size.
- **Smart route**: the fastest order of objectives and turn-ins. You can pick a strategy: balanced, turn in first, quest first or nearest. It learns your kill speed, drop rates and run speed, and can keep the route until you recalculate.
- **GPS**: your own stops plus the quest route, known flight paths when they save time, a panel with direction, distance and arrival time, the route on the minimap, and a stop list next to the world map.
- **Arrow** to the next stop or the selected quest.
- **Learned paths**: it remembers where you walk (account wide, all your characters) and the arrow follows those paths when that is shorter than going straight over unknown ground. `/roa trails` shows what it knows, `/roa trails clear` forgets it. The **Paths** button on the world map shows them as a heatmap (blue = once, red = your main roads).
- **Route on the world map**: numbered stops with lines between them.
- **Scrum of Azeroth**: epic groups, the sprint line and priority markers in the tracker. A locked route counts as the sprint.

## Commands
- `/roa`: settings
- `/roa recalc`: plan the route again from where you are
- `/roa clear`: clear the GPS route
- `/roa unlock` / `/roa lock`: move the frames

## Within the rules
Only the official add-on API. It shows information and points the way; it never moves your character, accepts or turns in quests, or casts anything. WoW gives add-ons no terrain or path data, so paths are learned only from your own position while you walk.

## Coming from CasterKit
Your quest list, route, GPS and arrow settings, the learned kill and drop data, and the frame positions are copied over automatically on the first login.

## API
`RoadsOfAzeroth.API` (with a `version` field) offers `GetRoutePlan`, `IsRouteLocked`, `GetFrozenRoute`, `SetFrozenRoute`, `Recalculate`, `RequestReplan`, `LockRoute`, `GetRouteStrategies`, `GetRouteStrategy`, `SetRouteStrategy`, `HasTracker`, `SelectQuest`, `SelectedQuest`, `OpenQuest`, `AddStop`, `PointTo`, `ClearRoute`, `RegisterEpicProvider`, `NotifyEpicsChanged` and `ToggleConfig`. It also has CallbackHandler events: `ROA_ROUTE_CHANGED` and `ROA_ROUTE_RECALCULATED`.

Saved data lives in `RoadsOfAzerothDB` (account; learned paths in `trails`) and `RoadsOfAzerothCharDB` (character; groups `quests`, `nav`, `map`, `arrow`, `questLearn`, `points`).

---

## Nederlands

Een questlijst met een slimme questroute, een GPS met vliegroutes, een navigatiepijl en de route op de wereldkaart. Het hoorde vroeger bij CasterKit (nu **Casters of Azeroth**) en werkt alleen of samen met **Casters of Azeroth** en **Scrum of Azeroth**.

Typ `/roa` voor de instellingen. Je instellingen uit CasterKit worden bij de eerste keer inloggen vanzelf overgezet. Alleen de officiële add-on-API: de addon toont informatie en wijst de weg, maar beweegt nooit je personage en neemt nooit zelf quests aan of levert ze in.

**Geleerde paden**: de addon onthoudt waar je loopt (voor al je personages samen). De pijl volgt die paden als dat korter is dan rechtdoor over onbekend terrein. `/roa trails` toont wat hij kent, `/roa trails clear` vergeet het. De knop **Paden** op de wereldkaart toont ze als heatmap (blauw = één keer, rood = je hoofdwegen).

Roboto font: Apache License 2.0 (see `media/LICENSE-Roboto.txt`).
