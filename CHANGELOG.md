# Changelog

## 0.2.0 — 2026-10-18

- Level-up announcements: when you level up, Quest Together posts in party chat how many
  quests you turned in at the level you just finished, e.g. "[Quest Together]: 7 quests
  completed at Level 12!". The quest whose turn-in levels you up counts toward the old level.
  A level the addon only saw part of isn't posted. On by default; "Announce level-ups" in the
  options and the panel's menu.
- Finishing a quest's last objective now posts only the objective ("6/6 Boar slain for
  [The Boar Hunt]!"). The extra "Quest Completed: [The Boar Hunt]" line, which mostly repeated
  it, is gone, and so is the "Announce completed quests" option.

## 0.1.0 — 2026-10-11

First version.

- Shares every quest you accept with your party, skipping members who already have it, never
  sharing back a quest a party member shared with you, and only once when two players with
  the addon take the same quest. One share at a time, waiting for everyone's answer.
- "Share quests the party is missing" (`/qt share`, the panel's menu, the options).
- Optional: accept quests your party members share with you.
- Posts finished objectives and completed quests in party chat, worded like Questie's.
- Party progress panel: everyone's progress on the quests whose area you're in (or in this
  zone, or every quest the party shares), synced between Quest Together users and filled in
  from the game for the others.
- Options in Options > AddOns > Quest Together; `/qt debug` diagnostics.
