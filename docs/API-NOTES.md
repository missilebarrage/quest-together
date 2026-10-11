# Client API notes

Facts about the WoW Forever client (game type `camelot`, Interface 16001) that Quest Together
relies on. Source: the Blizzard UI code mirror (GitHub Gethe/wow-ui-source, branch `forever`,
build 1.60.1.70338), unless marked otherwise. "Unverified" items are on the in-game checklist
(`docs/VERIFICATION.md`).

## Quest log

- `C_QuestLog.GetNumQuestLogEntries()` → `numShownEntries, numQuests`; `C_QuestLog.GetInfo(i)`
  → `QuestInfo` (`questID`, `title`, `isHeader`, `isHidden`, `isOnMap`, `hasLocalPOI`, ...).
- `C_QuestLog.GetQuestObjectives(questID)` → `{ text, type, finished, numFulfilled,
  numRequired, objectiveType? }[]`, may return nothing while the quest loads.
  `C_QuestLog.RequestLoadQuestByID` asks for it; `QUEST_DATA_LOAD_RESULT(questID, success)`.
- Also used: `IsComplete`, `ReadyForTurnIn`, `IsFailed`, `IsOnQuest`, `IsPushableQuest`,
  `GetLogIndexForQuestID`, `GetTitleForQuestID`, `GetSelectedQuest`/`SetSelectedQuest`.
  `GetQuestLink(questID)` is an undocumented global (`QuestMapFrame.lua` uses it).
- None of these, nor their events, carry secret-value flags (only
  `SecretArguments = "AllowedWhenUntainted"`).
- Events: `QUEST_LOG_UPDATE` (no payload, frequent), `QUEST_ACCEPTED(questID)` (Forever: no
  log index), `QUEST_REMOVED(questID, wasReplayQuest)`, `QUEST_TURNED_IN(questID, xp, money)`,
  `QUEST_WATCH_UPDATE(questID)`, `UNIT_QUEST_LOG_CHANGED(unit)`.
- Forever writes objective text count first: `"5/5 Windstone Cluster"` (Questie's tests).
  Some objectives report `1/1` while `finished` is false (Questie forces them to 0), and text
  can be half loaded (`" : 0/1"`, `"0/1  "`).

## Sharing

- `QuestLogPushQuest(logIndex)` is an undocumented global. Blizzard's Share button:
  `QuestMapQuestOptions_ShareQuest` → `QuestLogPushQuest(C_QuestLog.GetLogIndexForQuestID(id))`
  (`Blizzard_UIPanels_Game/Mainline/QuestMapFrame.lua`), enabled when
  `C_QuestLog.IsPushableQuest(id) and IsInGroup()`. Some addons select the quest first and
  call it without an index, so Quest Together does both.
- **Unverified:** whether it works outside a hardware event. RestedXP Guides and
  wow-autoshare (both declaring 16001) call it from `QUEST_ACCEPTED` handlers.
- The answers are the `ERR_QUEST_PUSH_*_S` global strings (`SUCCESS` "Sharing quest with
  %s...", `ACCEPTED`, `DECLINED`, `BUSY`, `ONQUEST`, `ALREADY_DONE`, `INVALID`, `LOG_FULL`,
  `TOO_FAR`, ...). They don't name the quest. They arrive as `UI_INFO_MESSAGE(type, text)` —
  `GetGameMessageInfo(type)` returns the global's name — or as `CHAT_MSG_SYSTEM` (secret during
  chat lockdown). **Unverified** which one Forever uses.
- Receiving a share opens the quest dialog: `QUEST_DETAIL`, with `UnitGUID("questnpc")` the
  sharing player (Questie relies on this) and `GetQuestID()` the quest; `AcceptQuest()`.
- Party Sync is off on camelot (`Camelot/QuestMapFrameUtils.lua`: `IsPartySyncEnabled` false).

## Party members' quests

- `C_QuestLog.IsUnitOnQuest(unit, questID)` exists (Blizzard's
  `QuestUtils_GetNumPartyMembersOnQuest`). **Unverified** that it answers on camelot.
- `C_TooltipInfo.GetQuestPartyProgress(questID, omitTitle, ignoreActivePlayer)` →
  `TooltipData` whose lines have `type` (`QuestPlayer` 18, `QuestObjective` 8, `QuestTitle`
  17), `leftText` and `completed`. Blizzard shows it in quest tooltips. **Unverified** on
  camelot.

## Quest areas

- `C_Minimap.IsInsideQuestBlob(questID)` and
  `PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED(questID, isInside)` (`MinimapDocumentation.lua`).
  Blizzard uses them for the glow on quest item buttons. **Unverified** for quests that aren't
  tracked, hence the 2-second poll and the "In this zone" mode.
- The world map draws blobs on camelot (`QuestBlobDataProvider`, a `QuestPOIFrame` pin) for
  the tracked, highlighted or focused quest; camelot keeps quest POI tracking always on for the
  minimap (`Blizzard_Minimap/Camelot/MinimapConstants.lua`).

## Chat and addon messages

- Post with `C_ChatInfo.SendChatMessage(text, "PARTY")`; the global `SendChatMessage` only
  exists with the `loadDeprecationFallbacks` CVar. `SendChatMessage` has `HasRestrictions`;
  PARTY posts from event handlers work on Forever for other addons (GUILD needs a hardware
  event). `{rt1}` shows as the star raid marker.
- `C_ChatInfo.InChatMessagingLockdown()`; the lockdown ends with
  `ADDON_RESTRICTION_STATE_CHANGED` (its payload isn't relied on).
- `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` (at most 16 characters);
  `C_ChatInfo.SendAddonMessage(prefix, text, chatType)` (text at most 255 bytes, no secret
  arguments) → `Enum.SendAddonMessageResult`: `Success` 0, `AddonMessageThrottle` 3,
  `NotInGroup` 5, `ChannelThrottle` 8, `AddOnMessageLockdown` 11, `TargetOffline` 12.
  `CHAT_MSG_ADDON(prefix, text, channel, sender, ...)` isn't secret; party messages come back
  to their sender.
- `AreOutgoingAddonChatMessagesRestricted()` is about tournament realms and is true on
  Forever; it doesn't stop party addon messages.
- Sender and unit names on Forever are "First Surname" (`UnitName` returns the surname as its
  second value), sometimes with "-Realm" (Questie's `CommsRouting.lua`).

## General

- Deprecated globals are absent unless a CVar is set: use the `C_` functions.
- `ReloadUI()` is blocked for addons; a new addon folder only loads after a full client
  restart.
- Unit identity can be a secret value in restricted content (`issecretvalue`); everything
  read from the game goes through `ns.Str` / `ns.Num` / `ns.Bool`.
