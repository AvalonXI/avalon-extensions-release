# avalonlogin

Ashita v4 addon that bridges your character to the AvalonXI launcher's "Welcome back" card, and greets a brand-new character once.

## What it does

- On login (and every zone) writes a small `<Ashita>/config/avalonlogin.json` with your current character name, zone, and a timestamp.
- The AvalonXI launcher reads that file so its home card can greet you by character **name** - never your account login.
- Greets a brand-new character once, pointing at `/wiki`.

## Load

`/addon load avalonlogin`

Ships default-on in the AvalonXI launcher's managed add-on set, so you don't load it manually.

## Slash commands

None - the addon is passive.
