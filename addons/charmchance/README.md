# charmchance

Ashita v4 addon for estimating Beastmaster charm success on the current target.

## Commands

- `/charm` (or `/charm toggle`) - show or hide the charm % panel
- `/charm chance` - print the full charm estimate breakdown to chat
- `/charm lock [on|off]` - lock the panel in place; bare `/charm lock` toggles it
- `/charm reload` (`/charm rl`) - reload settings from disk
- `/charm reset` - reset settings to defaults
- `/charm help` - show command help

## Panel

A minimal on-screen panel shows the charm estimate for your current target as two centered lines: a `Charm Chance` label and the percentage, color-coded by the estimate (green / yellow / red). It appears only while an enemy is targeted and is hidden whenever you have no target. Draggable unless locked (`/charm lock`); position persists per character. The estimate is approximate; it refreshes on target change and about once a second for the same target, so live gear / merit changes are reflected. Use `/charm chance` for the full breakdown.
