# Avalon Extensions (Release)

Drop-in Ashita v4 addons and plugins for AvalonXI.

Built and maintained from the private [`avalon-extensions`](https://github.com/AvalonXI/avalon-extensions) repository; this repo is a verbatim mirror of its `public/` tree.

## Install

1. Download or clone this repo.
2. Copy the contents of `addons/` into your Ashita `addons/` folder, e.g.:
   ```
   C:\Program Files (x86)\PlayOnline\Ashita\addons\
   ```
3. If a `plugins/` folder is present, copy its `.dll` files into your Ashita `plugins/` folder.
4. In game, load each addon with `/addon load <name>`.

## Addons

### `retainer`
- `/addon load retainer` (alias `/ret`)
- Slash commands: `/retainer ...`
- Stash-style ImGui panel: one-click full Sync of stored materials, craft grouping
  + live filter, 1 / Stack / Half / Full withdrawals, and a Deposit view.
- Requires an AvalonXI server that supports `!retainer`.

### `charmchance`
- `/addon load charmchance`
- Slash commands: `/charm chance`, `/charm help`
- Beastmaster charm-rate estimator using generated zone/name data and the live charm formula.
- Includes a lightweight floating HUD.

### `avalonwiki`
- `/addon load avalonwiki`
- Slash commands: `/wiki`, `/wiki <page or query>`
- Opens the AvalonXI Miraheze wiki in the default browser.

### `avalonbeta`
- `/addon load avalonbeta`
- Slash commands: `/beta ...`
- Floating ImGui panel that queues AvalonXI's rank-5 `!dev` / beta-test commands.
- Server-gated: the panel only sends the `!` commands, so non-dev characters get
  the normal server permission error.

## Notes

- Per-character settings and cache data are stored by Ashita under `config/addons/`.
- Addons rely on AvalonXI server chat output, not hidden client-side data.
- Support: see the AvalonXI Discord.
