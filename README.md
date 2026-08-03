# Avalon Extensions (Release)

Drop-in Ashita v4 addons for AvalonXI.

Built and maintained from the private
[`avalon-extensions`](https://github.com/AvalonXI/avalon-extensions) repository;
this repo is a verbatim mirror of its `public/` tree.

## Install

1. Download or clone this repo.
2. Copy the contents of `addons/` into your Ashita `addons/` folder, e.g.:
   ```
   C:\Program Files (x86)\PlayOnline\Ashita\addons\
   ```
3. In game, load each addon with `/addon load <name>`.

## Addons

| Addon | Load | Main commands | Surface |
|---|---|---|---|
| [retainer](addons/retainer/README.md) | `/addon load retainer` | `/retainer`, `/ret` | Stash-style panel for AvalonXI `!retainer` material storage: full Sync, craft grouping and filter, withdraw and deposit flows. |
| [charmchance](addons/charmchance/README.md) | `/addon load charmchance` | `/charm`, `/charm chance` | Beastmaster charm-rate estimate for the current target, with a floating HUD, from generated lookup data. |
| [avalonwiki](addons/avalonwiki/README.md) | `/addon load avalonwiki` | `/wiki` | Opens the AvalonXI wiki in the default browser from an in-game command. |
| [avalonbeta](addons/avalonbeta/README.md) | `/addon load avalonbeta` | `/beta` | Panel that queues AvalonXI `!dev` commands; server permission rules apply. |
| [avalonlogin](addons/avalonlogin/README.md) | Default-on | None | Writes the launcher identity bridge file on login and zone changes so the AvalonXI launcher can greet your character. |

## Notes

- Per-character settings and cache data are stored by Ashita under `config/addons/`.
- Addons rely on AvalonXI server chat output, not hidden client-side data.
- Support: see the AvalonXI Discord.
