# In-game verification

The test suite runs Quest Together against a fake game API, so a few things can only be
confirmed in the real client. Install with `scripts/install.sh`, restart the game (a new addon
needs a full restart; later changes only need `/reload`), then go through this list with two
characters in a party (two accounts, or a friend), both with the addon unless noted.
`/qt debug ...` prints quest IDs, counts and unit tokens only.

The first section decides which fallbacks matter, so run it first. Record results under
**Results** with the date and client build.

## 1. Probes

- [ ] `/qt debug`: every API on the `APIs:` line says `yes`.
- [ ] **Sharing from addon code.** Accept a quest while in a party. About 2 seconds later the
      other character gets the quest dialog, and the sharer sees "Sharing quest with ...".
      `/qt debug share`: `pushed=1`, `silent=0`, and the recent answers list `sending` and
      `accepted`/`declined` with `party1`. If nothing happens and `silent=1`, or the addon says
      the game doesn't let it share: sharing needs a key press or click on Forever.
- [ ] Where the answers come from: if `/qt debug share` lists answers, they're understood.
      Note whether the "Sharing quest with ..." text showed in chat (system message) or in the
      middle of the screen (info message).
- [ ] **Party members' quests from the game.** `/qt debug peers` with a party member who
      shares some of your quests: `unit-on-quest ... yes` above 0 and `proven yes`.
- [ ] **Quest areas.** Walk into the area of a quest (its shape on the map): `/qt debug areas`
      shows `in area now yes` for it. Check a quest you're tracking and one you aren't, and
      whether `area events` goes up (the game's event) or only `polls`.
- [ ] **Game party progress.** `/qt debug tooltip <questID>` for a quest both characters have:
      note the line count, line types and members found.
- [ ] **Collapsed headers.** Collapse a zone header in the quest log and `/reload`:
      `/qt debug quests` should say the log listed all of its quests (e.g. "listed 12 of its 12").
      If it lists fewer, quests under collapsed headers are missed until they change.
- [ ] **Party chat.** Finish an objective: the party sees `6/6 ... for [Quest]!` after a star
      icon, with a clickable quest link.

## 2. Sharing

- [ ] The other character accepts: their addon doesn't share the quest back.
- [ ] Both characters accept the same quest from an NPC at the same time: only one share
      arrives (for a third member, if there is one).
- [ ] A member who already has the quest gets no dialog (`skipped` in `/qt debug share`).
- [ ] Accept two quests quickly: the second share waits until the first is answered.
- [ ] Turn on "Accept quests the party shares" on the other character: shared quests are
      accepted without the dialog.
- [ ] A member joins late: the panel menu's "Share quests the party is missing (N)" shares them
      one by one and prints a summary; `/qt share stop` stops it.
- [ ] In combat, a share waits until combat ends.

## 3. Announcements

- [ ] Finishing an objective posts once; finishing the last one posts the objective, then
      "Quest Completed: [Quest]".
- [ ] `/reload` with finished objectives: nothing is posted.
- [ ] Solo: nothing is posted, and nothing later for objectives finished while solo.
- [ ] Inside a dungeon during a boss fight (chat lockdown): lines wait and post after the fight
      (`/qt debug chat`).
- [ ] With Questie loaded, the one-time notice appears.

## 4. Panel

- [ ] In a quest's area, the panel appears with You and the party member as columns; counts
      update as either character progresses; finished objectives show a green check.
- [ ] A member without the quest is listed under "Not on quest"; one without the addon shows
      the game's numbers, `?` or "No info".
- [ ] Leaving the area: the quest stays for about 5 seconds, then the panel hides.
- [ ] Finishing a quest in its area keeps it shown until the other character finishes too.
- [ ] Right-click menu: modes, switches, share, options, hide. Shift-drag moves it and the
      position survives `/reload`. Size and background options work. `/qt preview` while solo.
- [ ] The check icon shows (otherwise `/qt debug` lists it under missing icons); long names
      are cut with "..." and stay in their columns; class colours look right.
- [ ] With EllesmereUI: the quest titles follow its accent colour; its font is used.

## 5. Sync

- [ ] `/reload` on one character: within a few seconds the other's panel shows its progress
      again, and it shows the other's.
- [ ] Leave and rejoin the party: progress comes back.
- [ ] `/qt debug comm`: no `throttled` or `dropped` counts during normal play.

## Results

_Nothing recorded yet._
