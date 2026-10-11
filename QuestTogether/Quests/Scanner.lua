local _, ns = ...

--- Keeps a snapshot of the player's quests and reports what changed. Announcements,
--- party sync and the panel all read this snapshot, never the quest log directly.
---
--- Signals (fired after a scan has updated the whole snapshot, in log order; for each
--- quest objective-done comes before quest-done, which comes before changed):
---   QT_QUEST_ADDED(questID)          first complete read of a quest (login, accept, late load)
---   QT_OBJECTIVE_DONE(questID, i, silent)  objective i went from unfinished to finished
---   QT_QUEST_DONE(questID, nil, silent)   every objective finished (ready to turn in)
---   QT_QUEST_CHANGED(questID)        counts or state changed
---   QT_QUEST_REMOVED(questID)        turned in, abandoned or gone from the log
---   QT_SCAN_DONE                     after every scan
---
--- The first complete read of a quest is its baseline and never reports objectives as
--- done, so logging in or accepting a finished quest announces nothing. For a few seconds
--- after a loading screen the client can report stale, lower counts: decreases are held
--- back until that has passed, and a quest first read in that window reports what it
--- finishes during it as `silent` (most likely stale data catching up, not progress).
---@class QTScanner
local Scanner = ns.Scanner
local QuestLog = ns.QuestLog
local Events = ns.Events

local SCAN_DELAY = 0.25
local SETTLE_SECONDS = 5
local RETRY_DELAY = 1
local MAX_RETRIES = 10
-- Scans a quest may be missing from the log before it counts as gone.
local MISSING_SCANS = 2

---@class QTQuest: QTQuestRead
---@field logIndex integer?
---@field isOnMap boolean
---@field provisional boolean? first read during a settle window, which hasn't ended yet

local records = {} ---@type table<integer, QTQuest>
local order = {} ---@type integer[] quests with a record, in log order
local known = {} ---@type table<integer, boolean> quests seen in the log or accepted
local retries = {} ---@type table<integer, integer>
local missing = {} ---@type table<integer, integer>
local started = false
local settleUntil = 0
local settleRescan = false

-- Reused on every scan.
local scratch = { objectives = {} } ---@type QTQuestRead
local listed = {} ---@type integer[]
local inLog = {} ---@type table<integer, table> log info by quest ID for this scan
local extra = {} ---@type integer[]
local signalNames, signalQuests, signalIndexes, signalSilent, signalCount = {}, {}, {}, {}, 0

local stats = { scans = 0, partial = 0, lastMs = 0, held = 0, listed = 0, logQuests = 0 }

local function Signal(name, questID, index, silent)
	signalCount = signalCount + 1
	signalNames[signalCount], signalQuests[signalCount] = name, questID
	signalIndexes[signalCount], signalSilent[signalCount] = index, silent == true
end

local function FlushSignals()
	local count = signalCount
	signalCount = 0
	for index = 1, count do
		Events.Fire(signalNames[index], signalQuests[index], signalIndexes[index], signalSilent[index])
		signalNames[index], signalQuests[index], signalIndexes[index], signalSilent[index] = nil, nil, nil, nil
	end
end

local function Visit(questID, info)
	if not inLog[questID] then
		listed[#listed + 1] = questID
		inLog[questID] = info
		known[questID] = true
	end
end

local function CopyObjective(target, source)
	target.label = source.label
	target.hadCount = source.hadCount
	target.fulfilled = source.fulfilled
	target.required = source.required
	target.done = source.done
	target.hidden = source.hidden
end

--- Whether the new read lowers anything the snapshot has.
local function Decreases(record, read)
	if record.complete and not read.complete then
		return true
	end
	local objectives = record.objectives
	if #read.objectives < #objectives then
		return true
	end
	for index, old in ipairs(objectives) do
		local new = read.objectives[index]
		if new.fulfilled < old.fulfilled or (old.done and not new.done) then
			return true
		end
	end
	return false
end

local function Settling()
	return GetTime() < settleUntil
end

---@return QTQuest
local function NewRecord(read)
	local record = { questID = read.questID, objectives = {} }
	record.title = read.title
	record.complete = read.complete
	record.failed = read.failed
	record.visible = read.visible
	-- Read right after a loading screen, the first counts may be stale: whatever finishes
	-- while the window lasts was likely finished already, so it's reported as silent.
	record.provisional = Settling()
	for index, objective in ipairs(read.objectives) do
		local copy = {}
		CopyObjective(copy, objective)
		record.objectives[index] = copy
	end
	return record
end

--- Applies a complete read to an existing record and queues the signals it causes.
local function Apply(record, read)
	local questID = record.questID
	local silent = record.provisional == true
	local changed = false
	record.title = read.title
	record.visible = read.visible
	local objectives = record.objectives
	for index, new in ipairs(read.objectives) do
		local old = objectives[index]
		-- An objective that appears already finished was never seen unfinished.
		local wasDone = old == nil or old.done
		if not old then
			old = {}
			objectives[index] = old
			changed = true
		elseif
			old.fulfilled ~= new.fulfilled
			or old.required ~= new.required
			or old.done ~= new.done
			or old.label ~= new.label
			or old.hidden ~= new.hidden
		then
			changed = true
		end
		CopyObjective(old, new)
		if new.done and not wasDone then
			Signal("QT_OBJECTIVE_DONE", questID, index, silent)
		end
	end
	for index = #objectives, #read.objectives + 1, -1 do
		objectives[index] = nil
		changed = true
	end
	local wasComplete = record.complete
	if record.complete ~= read.complete or record.failed ~= read.failed then
		changed = true
	end
	record.complete, record.failed = read.complete, read.failed
	if read.complete and not wasComplete then
		Signal("QT_QUEST_DONE", questID, nil, silent)
	end
	if changed then
		Signal("QT_QUEST_CHANGED", questID)
	end
end

local function Remove(questID)
	if not records[questID] then
		known[questID], retries[questID], missing[questID] = nil, nil, nil
		return
	end
	records[questID] = nil
	known[questID], retries[questID], missing[questID] = nil, nil, nil
	for index = #order, 1, -1 do
		if order[index] == questID then
			table.remove(order, index)
		end
	end
	Events.Fire("QT_QUEST_REMOVED", questID)
end

local Scan

local function ScheduleScan(delay)
	Events.Debounce("scan", delay or SCAN_DELAY, Scan)
end

--- Reads one quest; returns whether it still needs another attempt.
local function ReadQuest(questID, info)
	if not QuestLog.Read(questID, scratch) then
		stats.partial = stats.partial + 1
		if not retries[questID] then
			QuestLog.RequestLoad(questID)
		end
		retries[questID] = (retries[questID] or 0) + 1
		return retries[questID] <= MAX_RETRIES
	end
	retries[questID] = nil
	local record = records[questID]
	if not record then
		record = NewRecord(scratch)
		records[questID] = record
		Signal("QT_QUEST_ADDED", questID)
	elseif Settling() and Decreases(record, scratch) then
		stats.held = stats.held + 1
		settleRescan = true
	else
		if record.provisional and not Settling() then
			record.provisional = nil
		end
		Apply(record, scratch)
	end
	record.logIndex = QuestLog.LogIndex(questID)
	record.isOnMap = info ~= nil and info.isOnMap == true
	return false
end

function Scan()
	if not started then
		return
	end
	local began = debugprofilestop()
	stats.scans = stats.scans + 1
	wipe(listed)
	wipe(inLog)
	wipe(extra)
	QuestLog.Walk(Visit)
	-- Quests the walk didn't list (under a collapsed header, for instance) are still read
	-- while the player is on them.
	for questID in pairs(known) do
		if not inLog[questID] then
			if QuestLog.IsOnQuest(questID) then
				extra[#extra + 1] = questID
			elseif records[questID] then
				missing[questID] = (missing[questID] or 0) + 1
				if missing[questID] >= MISSING_SCANS and not Settling() then
					Remove(questID)
				end
			else
				known[questID] = nil
			end
		end
	end
	-- The log's own count shows whether the walk missed quests (collapsed headers).
	stats.listed = #listed
	stats.logQuests = ns.Num(select(2, C_QuestLog.GetNumQuestLogEntries())) or 0
	table.sort(extra)
	for _, questID in ipairs(extra) do
		listed[#listed + 1] = questID
	end

	local retry = false
	for _, questID in ipairs(listed) do
		missing[questID] = nil
		if ReadQuest(questID, inLog[questID]) then
			retry = true
		end
	end

	wipe(order)
	for _, questID in ipairs(listed) do
		if records[questID] then
			order[#order + 1] = questID
		end
	end

	if retry then
		Events.Debounce("scanRetry", RETRY_DELAY, Scan)
	end
	if settleRescan then
		settleRescan = false
		Events.Debounce("scanSettled", math.max(0, settleUntil - GetTime()) + 0.05, Scan)
	end
	stats.lastMs = debugprofilestop() - began
	FlushSignals()
	Events.Fire("QT_SCAN_DONE")
end

--- Starts scanning (PLAYER_LOGIN): quest events before login are ignored.
function Scanner.Start()
	started = true
	ScheduleScan()
end

--- Requests a scan soon (debounced).
function Scanner.Request()
	ScheduleScan()
end

---@param questID integer
---@return QTQuest?
function Scanner.Get(questID)
	return records[questID]
end

--- Quest IDs with a snapshot, in quest log order. Don't modify the list.
---@return integer[]
function Scanner.Quests()
	return order
end

---@return boolean
function Scanner.IsSettling()
	return Settling()
end

--- Counters for /qt debug.
function Scanner.Stats()
	return stats, retries
end

local function OnLogChanged()
	ScheduleScan()
end

Events.On("QUEST_LOG_UPDATE", OnLogChanged)
-- Which quests the map shows here (the panel's zone mode) changes with the zone.
Events.On("ZONE_CHANGED_NEW_AREA", OnLogChanged)
Events.On("ZONE_CHANGED", OnLogChanged)
Events.On("QUEST_WATCH_UPDATE", OnLogChanged)
Events.On("QUEST_DATA_LOAD_RESULT", OnLogChanged)
Events.On("UNIT_QUEST_LOG_CHANGED", function(unit)
	if unit == "player" then
		ScheduleScan()
	end
end)
Events.On("QUEST_ACCEPTED", function(questID)
	questID = ns.Num(questID)
	if questID then
		known[questID] = true
	end
	ScheduleScan()
end)
Events.On("QUEST_REMOVED", function(questID)
	questID = ns.Num(questID)
	if questID then
		Remove(questID)
	end
end)
Events.On("PLAYER_ENTERING_WORLD", function()
	settleUntil = GetTime() + SETTLE_SECONDS
	ScheduleScan()
end)
