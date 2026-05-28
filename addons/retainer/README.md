# retainer

Ashita v4 addon for AvalonXI's `!retainer` material storage. A stash-style panel: pull your entire stored catalog in one click, filter it, and withdraw or deposit crafting materials straight from the list.

An Ashita port of Otamarai's Windower 4 retainer addon.

## What it does

- `/retainer` (alias `/ret`) toggles a draggable panel.
- **Sync** pulls your full stored catalog and caches it per character (browsable anywhere).
- Materials group by craft with a live filter; selecting a row gives **1 / Stack / Half / Full** withdraw buttons.
- A **Deposit** view lists depositable mats from your inventory with **1 / Stack / Half / All** buttons, plus **Store All Mats**.
- An always-visible inventory fill readout (used / capacity).

## Load

`/addon load retainer`

## Slash commands

- `/retainer` / `/ret` - toggle the panel
- `/retainer show` | `hide` | `toggle` - explicit visibility
- `/retainer sync` (`refresh`, `list`) - fetch the full stored list
- `/retainer store` (`storeall`) - deposit ALL storable mats from inventory
- `/retainer deposit` - open the per-item Deposit view
- `/retainer storable` - refresh the storable-item catalog (Deposit filter)
- `/retainer group [on|off]` - group stored items by craft
- `/retainer hidelines [on|off]` - hide the raw dump spam during a sync
- `/retainer query <item|id>` - one-off `!retainer` lookup (doesn't touch the cache)
- `/retainer clear` - wipe the local cache for this character
- `/retainer reload` | `reset` - reload / reset settings
- `/retainer help` - command list
