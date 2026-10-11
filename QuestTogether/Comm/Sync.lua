local _, ns = ...

--- Keeps party members who run the addon up to date with the player's quest progress, and
--- feeds what they send into PartyState.
---
---   * Joining a group, logging in or reloading while grouped: say hello (the others answer
---     with their full state) and send our own full state.
---   * Someone joins: send our full state (they need it), and say hello if their state is missing.
---   * Someone says hello: send our full state.
---   * Changes arrive from someone whose full state never did: say hello.
---   * A messaging lockdown ends: say hello and send our full state.
---   * A quest changes: send it within a second, batched with other changes.
--- Full states are sent at most every few seconds, after a short random delay, so a whole
--- party answering the same hello doesn't send at once.
---@class QTSync
local Sync = ns.Sync
local Protocol = ns.Protocol
local Transport = ns.Transport
local PartyState = ns.PartyState
local Scanner = ns.Scanner
local Roster = ns.Roster
local Events = ns.Events
local L = ns.L

local DELTA_DELAY = 1
local FULL_DELAY_MIN = 0.5
local FULL_DELAY_SPREAD = 2
local FULL_MIN_INTERVAL = 3
local RETRY_AFTER_DROP = 10
local HELLO_MIN_INTERVAL = 10

local dirty = {} ---@type table<integer, boolean>
local removed = {} ---@type table<integer, boolean>
local fullTimer
local lastFullAt = -math.huge
local syncCounter = 0
local currentFull ---@type string? group of the full state being sent
local lastHelloAt = -math.huge
local newerNoticeShown = false
local stats = { fulls = 0, deltas = 0, hellos = 0, received = {} }

local function Count(kind)
	stats.received[kind] = (stats.received[kind] or 0) + 1
end

local function Records(questIDs)
	local records = {}
	for _, questID in ipairs(questIDs) do
		local quest = Scanner.Get(questID)
		if quest then
			records[#records + 1] = Protocol.EncodeRecord(quest)
		end
	end
	return records
end

local function SendAll(messages, group)
	for _, text in ipairs(messages) do
		if not Transport.Send(text, group) then
			return false
		end
	end
	return true
end

local function SendFull()
	fullTimer = nil
	if not Roster.InGroup() then
		return
	end
	syncCounter = syncCounter + 1
	-- Short, and different from the previous one, so receivers can tell full states apart.
	local syncId = string.format("%x", (math.random(0, 0xfff) * 256 + syncCounter % 256))
	if currentFull then
		Transport.Discard(currentFull)
	end
	currentFull = "full" .. syncId
	local messages = Protocol.Full(syncId, Records(Scanner.Quests()))
	if SendAll(messages, currentFull) then
		lastFullAt = GetTime()
		stats.fulls = stats.fulls + 1
		-- A full state includes every pending change.
		wipe(dirty)
		wipe(removed)
	else
		-- Without its last part a full state is useless: try again later.
		Transport.Discard(currentFull)
		C_Timer.After(RETRY_AFTER_DROP, Sync.ScheduleFull)
	end
end

--- Sends the full state soon (once, however often it's asked for).
function Sync.ScheduleFull()
	if fullTimer or not Roster.InGroup() then
		return
	end
	local delay = FULL_DELAY_MIN + math.random() * FULL_DELAY_SPREAD
	delay = math.max(delay, lastFullAt + FULL_MIN_INTERVAL - GetTime())
	fullTimer = C_Timer.NewTimer(delay, SendFull)
end

local function SendDelta()
	if not Roster.InGroup() then
		wipe(dirty)
		wipe(removed)
		return
	end
	local changed, gone = {}, {}
	for questID in pairs(dirty) do
		if Scanner.Get(questID) then
			changed[#changed + 1] = questID
		end
	end
	for questID in pairs(removed) do
		if not Scanner.Get(questID) then
			gone[#gone + 1] = questID
		end
	end
	wipe(dirty)
	wipe(removed)
	table.sort(changed)
	table.sort(gone)
	if #changed > 0 then
		SendAll(Protocol.Delta(Records(changed)))
		stats.deltas = stats.deltas + 1
	end
	if #gone > 0 then
		SendAll(Protocol.Removed(gone))
	end
end

local function MarkDirty(questID)
	dirty[questID] = true
	removed[questID] = nil
	if Roster.InGroup() then
		Events.Debounce("syncDelta", DELTA_DELAY, SendDelta)
	end
end

local function MarkRemoved(questID)
	removed[questID] = true
	dirty[questID] = nil
	if Roster.InGroup() then
		Events.Debounce("syncDelta", DELTA_DELAY, SendDelta)
	end
end

--- Says hello, which asks every member's addon for its full state. Not more than every
--- few seconds unless `force`d.
---@param force boolean?
local function Hello(force)
	local now = GetTime()
	if not force and now - lastHelloAt < HELLO_MIN_INTERVAL then
		return
	end
	if Transport.Send(Protocol.Hello(ns.VERSION)) then
		lastHelloAt = now
		stats.hellos = stats.hellos + 1
	end
end

--- Tells the party the player is sharing a quest right now, so their own addon doesn't
--- share it too.
---@param questID integer
function Sync.AnnouncePush(questID)
	Transport.Send(Protocol.Push(questID))
end

local HANDLERS = {
	H = function(member, message)
		PartyState.Hello(member, message.addonVersion, message.version)
		Sync.ScheduleFull()
	end,
	F = function(member, message)
		PartyState.ApplyFull(member, message.syncId, message.part, message.total, message.records)
	end,
	-- Changes from someone whose full state never arrived (it was lost, or they started
	-- while the player's addon couldn't hear them): ask for it.
	D = function(member, message)
		if not PartyState.Apply(member, message.records) then
			Hello()
		end
	end,
	X = function(member, message)
		if not PartyState.Remove(member, message.ids) then
			Hello()
		end
	end,
	P = function(member, message)
		ns.Share.NotePeerPush(message.questID, member)
	end,
}

local function OnMessage(member, message)
	Count(message.kind)
	if message.newer then
		local peer = PartyState.Peer(member.guid)
		if not newerNoticeShown and not (peer and peer.synced) then
			newerNoticeShown = true
			ns.Print(L.NEWER_PEER)
		end
		return
	end
	HANDLERS[message.kind](member, message)
end

function Sync.Stats()
	return stats
end

Events.On("QT_QUEST_ADDED", MarkDirty)
Events.On("QT_QUEST_CHANGED", MarkDirty)
Events.On("QT_QUEST_REMOVED", MarkRemoved)
Events.On("QT_COMM_MESSAGE", OnMessage)
-- Whatever was said during a lockdown is lost both ways.
Events.On("QT_COMM_RESUMED", function()
	Hello(true)
	Sync.ScheduleFull()
end)
Events.On("QT_COMM_DROPPED", function(group)
	if group == currentFull then
		C_Timer.After(RETRY_AFTER_DROP, Sync.ScheduleFull)
	end
end)
Events.On("QT_ROSTER_CHANGED", function(added, _, joined)
	if not Roster.InGroup() then
		if fullTimer then
			fullTimer:Cancel()
			fullTimer = nil
		end
		wipe(dirty)
		wipe(removed)
		return
	end
	if joined then
		Hello(true)
	elseif added then
		-- Someone (back) in the party whose state the player doesn't have yet.
		for _, member in ipairs(Roster.Members()) do
			if not PartyState.IsSynced(member) then
				Hello()
				break
			end
		end
	end
	if added then
		Sync.ScheduleFull()
	end
end)
