# Quest Together

Questing in a party, made easier, for **World of Warcraft: Forever**. Quest Together shares
the quests you pick up with your party, posts in party chat when you finish an objective, and
shows everyone's progress on the quests around you in a small panel.

## Features

- **Shares your quests** — every quest you accept is shared with your party a moment later,
  skipping anyone who already has it. Quests a party member shared with you aren't shared
  back, and when two players with the addon take the same quest, only one of them shares it.
  Someone joined late? **Share quests the party is missing** (`/qt share`, the panel's menu or
  the options) offers them everything in your log they don't have, one quest at a time.
- **Accepts shared quests** (optional, off by default) — quests your party members share with
  you are accepted without the quest dialog.
- **Party chat announcements**, worded like Questie's (the line starts with a star icon):
  - `6/6 Boar slain for [The Boar Hunt]!` when you finish an objective;
  - `Quest Completed: [The Boar Hunt]` when the quest is ready to turn in.

  Each objective is posted once: logging in with finished objectives, or dropping below a
  count and getting back to it, posts nothing.
- **Party progress panel** — while you stand in a quest's area (the shape the map draws for
  it), a panel shows each party member's progress on it:

  ```
  The Boar Hunt      You  Thrall  Jaina
  Boar Tusk           ✓    4/6     2/6
  Bear Meat           ✓     ✓     3/10
  Not on quest: Anduin
  ```

  It shows only while you're in a party and there's progress to show. Shift-drag it to move
  it, right-click it to choose what it shows: quests in the areas you're in (the default),
  every quest in this zone, or every quest the party shares. Its size and background are in
  the options, and `/qt preview` shows it with example content so you can place it.
- **Fits your UI** — a flat, minimal look inspired by EllesmereUI; when EllesmereUI is
  installed, Quest Together follows its accent colour and font.

## How progress gets to the panel

- Party members who run **Quest Together** send their quest progress to the party over the
  addon channel: exact counts, updated within a second.
- For members **without the addon**, the panel uses what the game itself says: their progress
  when the game shares it, otherwise whether they're on the quest (`?`), or that they aren't.
  When the game can't tell, they're listed under "No info".

## Commands

| Command | |
| --- | --- |
| `/qt` | Show what's on and the commands |
| `/qt options` | Open the options |
| `/qt panel` | Turn the party progress panel on or off |
| `/qt preview` | Show the panel with example content for 30 seconds |
| `/qt share` | Share every quest someone in the party is missing |
| `/qt share stop` | Stop sharing |
| `/qt debug` | Diagnostics (`quests`, `areas`, `peers`, `tooltip <questID>`, `chat`, `share`, `comm`) |

Options are in **Options > AddOns > Quest Together**. `/questtogether` works as well as `/qt`.

## Questie and other addons

Questie can post finished objectives in party chat too. If both do, your party sees them
twice: turn the announcements off in one of the two. Quest Together mentions this once when
it finds Questie loaded. Other auto-share addons (RestedXP Guides' "share quests" option, for
example) would share your quests a second time.

## Privacy

- Party chat posts are only made while you're in a party (not a raid), and only for the two
  announcements above.
- To your party, over the addon channel, Quest Together sends quest IDs, objective counts and
  its version: never quest titles, objective text or names.
- Settings and the panel position are stored in your saved variables. `/qt debug` prints quest
  IDs, counts and unit tokens only, so it's safe to share.

## Development

Requirements: bash, curl, gcc/make and Python 3 (for unzipping). Everything else is pinned
and installed into the git-ignored `.tools/` folder.

```sh
scripts/bootstrap.sh   # Lua 5.1.5, luacheck and StyLua
scripts/test.sh        # lint, tests and the distribution check
scripts/install.sh     # copy QuestTogether/ into your AddOns folder ($QT_ADDONS_DIR or .tools/addons-path)
scripts/package.sh     # build a zip for manual installation
```

- `QuestTogether/` is the addon; only this folder ships. `tests/` runs the addon in a sandbox
  against a fake game API (`tests/harness/`), including several clients in one party
  (`tests/harness/network.lua`) for sharing and sync. `docs/API-NOTES.md` records the client
  facts the code relies on; `docs/VERIFICATION.md` is the in-game checklist.
- Code is formatted with StyLua and must pass luacheck. Every bug fix gets a regression test.
- Releases: tag `vX.Y.Z` and push; the GitHub workflow packages with the BigWigs packager and
  uploads to CurseForge (project 1739654, set in the TOC; needs the `CF_API_KEY` repository
  secret). `docs/CURSEFORGE.html` is the CurseForge project description, updated there by hand.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Blizzard Entertainment, Questie or
EllesmereUI.
