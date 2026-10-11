local _, ns = ...

--- Shares quests with the party: every quest the player accepts (when auto-share is on),
--- and on request every quest someone in the party is missing.
---
--- One share is in flight at a time. The game's answers don't name the quest, and a
--- member still looking at one shared quest answers "busy" to the next, so the next share
--- waits until everyone it was meant for has answered (or a timeout passes). Before each
--- share the addon works out who still needs the quest: members who already have it (as
--- their synced progress or the game says), declined it or can't take it are skipped, and
--- when nobody is left the share is skipped altogether.
---
--- A quest the player got shared by a party member isn't shared back, and when another
--- member's addon announces it's sharing a quest, the player's copy isn't shared again.
---@class QTShare
local Share = ns.Share
local Scanner = ns.Scanner
local QuestLog = ns.QuestLog
local Roster = ns.Roster
local PartyState = ns.PartyState
local Database = ns.Database
local Events = ns.Events
local L = ns.L

local AUTO_DELAY = 1.5
local AUTO_DELAY_SPREAD = 1.5
local STEP_INTERVAL = 0.5
local GAP_SECONDS = 2
local AUTO_TIMEOUT = 20
local MANUAL_TIMEOUT = 15
local BUSY_RETRY_SECONDS = 10
local MAX_BUSY_RETRIES = 1
local PEER_PUSH_SECONDS = 30

-- How long an answer keeps a member from being offered the quest again, in seconds, for
-- automatic shares and on request ("share missing"); nil: not at all. Members who have the
-- quest are skipped anyway; these cover what can't be seen otherwise. On request, only
-- answers that can't have changed since count.
local FOREVER = math.huge
local REMEMBER = {
	completed = { auto = FOREVER, manual = FOREVER },
	ineligible = { auto = 900, manual = 900 }, -- they may level up
	accepted = { auto = FOREVER, manual = 300 }, -- they may abandon it
	onQuest = { auto = FOREVER, manual = 300 },
	declined = { auto = FOREVER },
	logFull = { auto = 600 },
	tooFar = { auto = 600 },
}
-- Answers that end a member's part of the share in flight.
local ANSWERS = {
	accepted = true,
	declined = true,
	busy = true,
	onQuest = true,
	completed = true,
	ineligible = true,
	logFull = true,
	tooFar = true,
	expired = true,
}

---@class QTShareEntry
---@field questID integer
---@field manual boolean
---@field notBefore number
---@field busyRetries integer

---@class QTInFlight
---@field questID integer
---@field manual boolean
---@field startedAt number
---@field expected table<string, boolean> GUIDs still to answer
---@field count integer members the share was meant for
---@field remaining integer
---@field confirmed boolean the game said it's sending
---@field busy table<string, boolean>
---@field busyRetries integer
---@field cancelled boolean? stopped on request: no busy retry

local queue = {} ---@type QTShareEntry[]
local inFlight ---@type QTInFlight?
local memory = {} ---@type table<integer, table<string, {kind: string, at: number}>> last answer per quest and member
local peerPushes = {} ---@type table<integer, number>
local ticker
local lastFinishedAt = -math.huge
local blocked = false
local run ---@type {queued: integer, shared: integer, accepted: integer, declined: integer}?
local stats = { pushed = 0, skipped = 0, silent = 0, timeouts = 0, sharedBack = 0, peerShared = 0, lateAnswers = 0 }

local function StopTicker()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local Step

local function StartTicker()
	if not ticker then
		ticker = C_Timer.NewTicker(STEP_INTERVAL, function()
			Step()
		end)
	end
end

local function Remember(questID, guid, kind)
	if REMEMBER[kind] then
		memory[questID] = memory[questID] or {}
		memory[questID][guid] = { kind = kind, at = GetTime() }
	end
end

-- Answers about having the quest, which a member's synced state shows better.
local HAD_IT = { accepted = true, onQuest = true }

--- Whether a remembered answer still keeps the member from getting the quest.
local function Excluded(answer, manual, member)
	if not answer then
		return false
	end
	if HAD_IT[answer.kind] and PartyState.IsSynced(member) then
		return false
	end
	local rule = REMEMBER[answer.kind]
	local seconds = rule and rule[manual and "manual" or "auto"]
	return seconds ~= nil and GetTime() - answer.at < seconds
end

--- Members who should get the quest: connected, without it, and not known to have
--- turned it down or to be unable to take it.
---@param questID integer
---@param manual boolean
---@param into string[]? receives the GUIDs
---@return integer count
local function Targets(questID, manual, into)
	local count = 0
	local answers = memory[questID]
	for _, member in ipairs(Roster.Members()) do
		local answer = answers and answers[member.guid]
		if member.connected and not Excluded(answer, manual, member) and not PartyState.HasQuest(member, questID) then
			count = count + 1
			if into then
				into[count] = member.guid
			end
		end
	end
	return count
end

local function EndRun()
	if run and not inFlight then
		for _, entry in ipairs(queue) do
			if entry.manual then
				return
			end
		end
		ns.Print(L.SHARE_RUN_DONE:format(run.shared, run.accepted, run.declined))
		run = nil
	end
end

local function Finish()
	if not inFlight then
		return
	end
	if not inFlight.confirmed and inFlight.remaining == inFlight.count then
		-- No word from the game at all: sharing may not work from addon code here.
		stats.silent = stats.silent + 1
	end
	local busy = inFlight.busy
	if next(busy) and inFlight.busyRetries < MAX_BUSY_RETRIES and not inFlight.cancelled then
		queue[#queue + 1] = {
			questID = inFlight.questID,
			manual = inFlight.manual,
			notBefore = GetTime() + BUSY_RETRY_SECONDS,
			busyRetries = inFlight.busyRetries + 1,
		}
	end
	inFlight = nil
	lastFinishedAt = GetTime()
	EndRun()
end

local function Push(entry, targets, count)
	local questID = entry.questID
	local index = QuestLog.LogIndex(questID)
	if not index then
		return false
	end
	ns.Sync.AnnouncePush(questID)
	-- A blocked call is reported (ADDON_ACTION_BLOCKED) while it's being made.
	if not QuestLog.Push(questID, index) or blocked then
		return false
	end
	stats.pushed = stats.pushed + 1
	local expected = {}
	for position = 1, count do
		expected[targets[position]] = true
	end
	inFlight = {
		questID = questID,
		manual = entry.manual,
		startedAt = GetTime(),
		expected = expected,
		count = count,
		remaining = count,
		confirmed = false,
		busy = {},
		busyRetries = entry.busyRetries,
	}
	if run and entry.manual then
		run.shared = run.shared + 1
	end
	return true
end

local targetsScratch = {}

local function Skip()
	table.remove(queue, 1)
	stats.skipped = stats.skipped + 1
end

function Step()
	local now = GetTime()
	if inFlight then
		local timeout = inFlight.manual and MANUAL_TIMEOUT or AUTO_TIMEOUT
		if inFlight.remaining <= 0 then
			Finish()
		elseif now - inFlight.startedAt > timeout then
			stats.timeouts = stats.timeouts + 1
			Finish()
		end
		return
	end
	local entry = queue[1]
	if not entry then
		StopTicker()
		EndRun()
		return
	end
	if not Roster.InParty() or blocked then
		Share.Stop(true)
		return
	end
	if entry.notBefore > now or now - lastFinishedAt < GAP_SECONDS then
		return
	end
	-- Sharing opens a dialog for the others; not in the middle of a fight.
	if InCombatLockdown() or UnitAffectingCombat("player") then
		return
	end
	local questID = entry.questID
	if not entry.manual and peerPushes[questID] and now - peerPushes[questID] < PEER_PUSH_SECONDS then
		stats.peerShared = stats.peerShared + 1
		Skip()
		return
	end
	if not (Scanner.Get(questID) or QuestLog.IsOnQuest(questID)) or not QuestLog.IsPushable(questID) then
		Skip()
		return
	end
	wipe(targetsScratch)
	local count = Targets(questID, entry.manual, targetsScratch)
	if count == 0 then
		Skip()
		return
	end
	table.remove(queue, 1)
	if not Push(entry, targetsScratch, count) then
		stats.skipped = stats.skipped + 1
	end
end

--- Queues a quest unless it's already waiting; returns whether it was added.
---@param questID integer
---@param manual boolean
---@param delay number
---@return boolean
local function Enqueue(questID, manual, delay)
	for _, entry in ipairs(queue) do
		if entry.questID == questID then
			entry.manual = entry.manual or manual
			return false
		end
	end
	queue[#queue + 1] = { questID = questID, manual = manual, notBefore = GetTime() + delay, busyRetries = 0 }
	StartTicker()
	return true
end

--- How many quests in the log someone in the party is missing (and could be given).
---@return integer
function Share.MissingCount()
	if not Roster.InParty() then
		return 0
	end
	local count = 0
	for _, questID in ipairs(Scanner.Quests()) do
		if QuestLog.IsPushable(questID) and Targets(questID, true) > 0 then
			count = count + 1
		end
	end
	return count
end

--- Shares, one after another, every quest someone in the party is missing.
function Share.ShareMissing()
	if not Roster.InParty() then
		ns.Print(L.SHARE_NOT_IN_PARTY)
		return
	end
	if blocked then
		ns.Print(L.SHARE_BLOCKED)
		return
	end
	local queued = 0
	for _, questID in ipairs(Scanner.Quests()) do
		if QuestLog.IsPushable(questID) and Targets(questID, true) > 0 then
			if Enqueue(questID, true, 0) then
				queued = queued + 1
			end
		end
	end
	if queued == 0 then
		ns.Print(L.SHARE_NOTHING_MISSING)
		return
	end
	run = run or { shared = 0, accepted = 0, declined = 0 }
	ns.Print(L.SHARE_RUN_STARTED:format(queued))
	Step()
end

--- Cancels the quests waiting to be shared on request (all of them when `everything`).
---@param everything boolean?
function Share.Stop(everything)
	local stopped = 0
	for index = #queue, 1, -1 do
		if everything or queue[index].manual then
			table.remove(queue, index)
			stopped = stopped + 1
		end
	end
	if run then
		run = nil
		if not everything then
			ns.Print(L.SHARE_STOPPED)
		end
	end
	if everything then
		inFlight = nil
	elseif inFlight and inFlight.manual then
		-- Its answers still count, but it isn't tried again.
		inFlight.cancelled = true
	end
	if not queue[1] and not inFlight then
		StopTicker()
	end
	return stopped
end

--- Another member's addon is sharing this quest with the party.
---@param questID integer
function Share.NotePeerPush(questID)
	peerPushes[questID] = GetTime()
end

--- Whether a quest was just shared by a party member (so the player shouldn't share it back).
---@param questID integer
---@return boolean
function Share.FromParty(questID)
	local at = peerPushes[questID]
	return ns.AutoAccept.WasShared(questID) or (at ~= nil and GetTime() - at < PEER_PUSH_SECONDS * 2)
end

---@return table stats, QTShareEntry[] queue, QTInFlight? inFlight, boolean blocked
function Share.State()
	return stats, queue, inFlight, blocked
end

Events.On("QUEST_ACCEPTED", function(questID)
	questID = ns.Num(questID)
	if not questID or not Database.Get("autoShare") or not Roster.InParty() or blocked then
		return
	end
	if Share.FromParty(questID) then
		stats.sharedBack = stats.sharedBack + 1
		return
	end
	Enqueue(questID, false, AUTO_DELAY + math.random() * AUTO_DELAY_SPREAD)
end)

Events.On("QT_PUSH_RESULT", function(kind, member)
	if not inFlight then
		return
	end
	if kind == "sending" then
		inFlight.confirmed = true
		return
	end
	if not (member and ANSWERS[kind]) then
		return
	end
	inFlight.confirmed = true
	-- The answers don't name the quest: one from a member this share isn't waiting for (who
	-- already answered it, or is answering an earlier share late) isn't about this quest.
	if not inFlight.expected[member.guid] then
		stats.lateAnswers = stats.lateAnswers + 1
		return
	end
	if run and inFlight.manual then
		if kind == "accepted" then
			run.accepted = run.accepted + 1
		elseif kind == "declined" then
			run.declined = run.declined + 1
		end
	end
	if kind == "busy" then
		inFlight.busy[member.guid] = true
	else
		Remember(inFlight.questID, member.guid, kind)
	end
	inFlight.expected[member.guid] = nil
	inFlight.remaining = inFlight.remaining - 1
	if inFlight.remaining <= 0 then
		Finish()
	end
end)

Events.On("QT_ROSTER_CHANGED", function(_, removed)
	if not Roster.InParty() then
		Share.Stop(true)
		wipe(memory)
		return
	end
	if removed and inFlight then
		for guid in pairs(inFlight.expected) do
			if not Roster.FindByGUID(guid) then
				inFlight.expected[guid] = nil
				inFlight.remaining = inFlight.remaining - 1
			end
		end
	end
end)

Events.On("QT_QUEST_REMOVED", function(questID)
	memory[questID] = nil
end)

local function OnBlocked(addonName, func)
	if ns.Str(addonName) ~= ns.NAME or blocked then
		return
	end
	func = ns.Str(func) or ""
	if func:find("QuestLogPushQuest", 1, true) then
		blocked = true
		Share.Stop(true)
		ns.Print(L.SHARE_BLOCKED)
	end
end
Events.On("ADDON_ACTION_BLOCKED", OnBlocked)
Events.On("ADDON_ACTION_FORBIDDEN", OnBlocked)
