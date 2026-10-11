local _, ns = ...

--- /qt debug: diagnostics for checking the addon in game. Output holds quest IDs, unit
--- tokens ("party1"), counts and yes/no answers only — never names, titles or chat text —
--- so it can be shared safely.
---@class QTDebug
local Debug = ns.Debug
local Scanner = ns.Scanner
local QuestLog = ns.QuestLog
local Roster = ns.Roster
local PartyState = ns.PartyState
local GameProgress = ns.GameProgress
local Transport = ns.Transport
local Sync = ns.Sync
local Announce = ns.Announce
local PushResults = ns.PushResults
local Share = ns.Share
local AutoAccept = ns.AutoAccept
local Areas = ns.Areas
local Database = ns.Database
local Theme = ns.Theme
local L = ns.L

local function YesNo(value)
	if value == nil then
		return "-"
	end
	return value and L.YES_SHORT or L.NO_SHORT
end

local function Pairs(map)
	local parts = {}
	for key, value in pairs(map) do
		if type(value) ~= "table" then
			parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
		end
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "-"
end

local function Exists(value)
	return YesNo(value ~= nil)
end

local function General()
	local _, build, _, interface = GetBuildInfo()
	ns.Print(L.DEBUG_HEADER:format(ns.VERSION, tostring(build), tostring(interface)))
	ns.Print(
		L.DEBUG_APIS:format(
			Exists(QuestLogPushQuest),
			Exists(C_QuestLog.IsUnitOnQuest),
			Exists(C_Minimap and C_Minimap.IsInsideQuestBlob),
			Exists(C_TooltipInfo and C_TooltipInfo.GetQuestPartyProgress),
			Exists(C_ChatInfo.SendChatMessage),
			Exists(C_ChatInfo.InChatMessagingLockdown)
		)
	)
	local questie = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Questie")
	ns.Print(
		L.DEBUG_STATE:format(
			YesNo(Roster.InGroup()),
			YesNo(IsInRaid()),
			#Roster.Members(),
			#Scanner.Quests(),
			YesNo(questie == true),
			YesNo(Database.IsReadOnly())
		)
	)
	ns.Print(L.DEBUG_SETTINGS:format(Pairs(Database.Settings())))
	ns.Print(L.DEBUG_COUNTERS:format(Pairs(ns.Counters)))
	local missing = Theme.MissingIcons()
	ns.Print(L.DEBUG_MISSING_ICONS:format(#missing > 0 and table.concat(missing, ", ") or "-"))
end

local function Quests()
	local stats, retries = Scanner.Stats()
	ns.Print(L.DEBUG_SCANS:format(stats.scans, stats.lastMs, stats.partial, stats.held, YesNo(Scanner.IsSettling())))
	ns.Print(L.DEBUG_LISTED:format(stats.listed, stats.logQuests))
	for _, questID in ipairs(Scanner.Quests()) do
		local quest = Scanner.Get(questID)
		local done = 0
		for _, objective in ipairs(quest.objectives) do
			done = done + (objective.done and 1 or 0)
		end
		ns.Print(
			L.DEBUG_QUEST:format(
				questID,
				done,
				#quest.objectives,
				YesNo(quest.complete),
				YesNo(QuestLog.IsPushable(questID)),
				YesNo(quest.isOnMap)
			)
		)
	end
	ns.Print(L.DEBUG_RETRIES:format(Pairs(retries)))
end

local function AreasProbe()
	local result, stats = Areas.Probe()
	ns.Print(L.DEBUG_AREAS:format(Areas.Mode(), YesNo(Areas.HasApi()), stats.events, stats.polls, stats.changes))
	for _, questID in ipairs(Scanner.Quests()) do
		local entry = result[questID]
		ns.Print(L.DEBUG_AREA:format(questID, YesNo(entry.now), YesNo(entry.inside), YesNo(entry.sticky)))
	end
end

local function Peers()
	local quests = Scanner.Quests()
	for _, member in ipairs(Roster.Members()) do
		local peer = PartyState.Peer(member.guid)
		local onQuest = 0
		for _, questID in ipairs(quests) do
			if PartyState.UnitOnQuest(member, questID) then
				onQuest = onQuest + 1
			end
		end
		local synced = 0
		if peer then
			for _ in pairs(peer.quests) do
				synced = synced + 1
			end
		end
		ns.Print(
			L.DEBUG_PEER:format(
				member.unit,
				peer and peer.addonVersion or "-",
				YesNo(peer and peer.synced),
				synced,
				peer and math.floor(GetTime() - peer.lastSeen) or -1,
				onQuest,
				#quests,
				YesNo(member.connected)
			)
		)
	end
	local partyStats, proven = PartyState.Stats()
	ns.Print(L.DEBUG_UNIT_ON_QUEST:format(partyStats.unitOnQuestCalls, partyStats.unitOnQuestYes, YesNo(proven)))
	ns.Print(L.DEBUG_GAME_PROGRESS:format(Pairs(GameProgress.Stats())))
	ns.Print(L.DEBUG_ROSTER:format(Pairs(Roster.Stats())))
end

local function Tooltip(argument)
	local questID = tonumber(argument) or Scanner.Quests()[1]
	if not questID then
		ns.Print(L.DEBUG_NO_QUEST)
		return
	end
	local summary = GameProgress.Probe(questID)
	ns.Print(
		L.DEBUG_TOOLTIP:format(
			questID,
			YesNo(summary.available),
			YesNo(summary.ok),
			summary.lines or 0,
			Pairs(summary.types),
			summary.members and table.concat(summary.members, ", ") or "-"
		)
	)
end

local function Chat()
	local stats, queued, blocked = Announce.Stats()
	local locked = C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
	ns.Print(L.DEBUG_CHAT:format(YesNo(ns.Bool(locked)), queued, YesNo(blocked), Pairs(stats)))
end

local function ShareState()
	local stats, queue, inFlight, blocked = Share.State()
	ns.Print(
		L.DEBUG_SHARE:format(
			YesNo(Database.Get("autoShare")),
			YesNo(blocked),
			#queue,
			inFlight and inFlight.questID or "-",
			inFlight and inFlight.remaining or 0,
			Pairs(stats)
		)
	)
	local acceptStats, acceptDisabled = AutoAccept.Stats()
	ns.Print(L.DEBUG_ACCEPT:format(Pairs(acceptStats), YesNo(acceptDisabled)))
	local now = GetTime()
	for _, result in ipairs(PushResults.Recent()) do
		ns.Print(L.DEBUG_PUSH_RESULT:format(math.floor(now - result.at), result.kind, result.unit or "?"))
	end
end

local function Comm()
	ns.Print(L.DEBUG_COMM:format(YesNo(Transport.IsPaused()), Transport.QueueLength(), Pairs(Transport.Stats())))
	local syncStats = Sync.Stats()
	ns.Print(L.DEBUG_SYNC:format(syncStats.fulls, syncStats.deltas, syncStats.hellos, Pairs(syncStats.received)))
end

local TOPICS = {
	quests = Quests,
	areas = AreasProbe,
	peers = Peers,
	tooltip = Tooltip,
	chat = Chat,
	share = ShareState,
	comm = Comm,
}

--- /qt debug [topic [argument]]
---@param text string
function Debug.Run(text)
	local topic, argument = (text or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local handler = TOPICS[topic]
	if handler then
		handler(argument)
	else
		General()
	end
end
