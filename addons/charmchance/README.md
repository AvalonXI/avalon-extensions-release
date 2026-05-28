# charmchance

Ashita v4 addon for estimating Beastmaster charm success on the current target.

## Commands

- `/charm` (or `/charm toggle`) - show or hide the charm % panel
- `/charm chance` - print the full charm estimate breakdown to chat
- `/charm reload` (`/charm rl`) - reload settings from disk
- `/charm reset` - reset settings to defaults
- `/charm help` - show command help

## Panel

A minimal on-screen panel shows the current target's charm estimate: `Charm X%` and the target name, color-coded by the estimate (green / yellow / red), grey with no target. Draggable; position and size persist per character. The estimate is approximate and updates when your target changes; use `/charm chance` for the full breakdown.
