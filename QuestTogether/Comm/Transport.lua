local _, ns = ...

--- Sends and receives the addon's party messages. Outgoing messages wait in a queue that a
--- ticker drains, backing off when the client throttles and pausing while addon messages
--- are locked down. Incoming messages are parsed and handed on as
--- QT_COMM_MESSAGE(member, message); messages from the player or from anyone who isn't a
--- party member are dropped. QT_COMM_RESUMED fires when a lockdown ends.
---@class QTTransport
local Transport = ns.Transport
local Protocol = ns.Protocol
local Roster = ns.Roster
local Names = ns.Names
local Events = ns.Events

Transport.PREFIX = "QuestTogether"
local CHANNEL = "PARTY"

local SEND_INTERVAL = 0.25
local MAX_ATTEMPTS = 3
local RESUME_CHECK_SECONDS = 5
-- Messages still locked right after resuming: wait longer each time, up to this.
local MAX_PAUSE_SECONDS = 60
local MAX_QUEUE = 60

local Result = Enum and Enum.SendAddonMessageResult or {}
local SUCCESS = Result.Success or 0
local THROTTLED = {
	[Result.AddonMessageThrottle or 3] = true,
	[Result.ChannelThrottle or 8] = true,
}
local LOCKDOWN = Result.AddOnMessageLockdown or 11
local NOT_IN_GROUP = Result.NotInGroup or 5

---@class QTOutgoing
---@field text string
---@field group string? messages that only make sense together (the parts of one full state)
---@field attempts integer
---@field notBefore number?

local queue = {} ---@type QTOutgoing[]
local pump
local resumeTicker
local paused = false
local pausedAt = 0
local pauseSeconds = RESUME_CHECK_SECONDS
local resumedAt = -math.huge
local registered = false
local stats = {
	sent = 0,
	received = 0,
	throttled = 0,
	dropped = 0,
	lockdowns = 0,
	unknownSender = 0,
	malformed = 0,
	bytesOut = 0,
	bytesIn = 0,
	lastResult = nil,
}

local function StopPump()
	if pump then
		pump:Cancel()
		pump = nil
	end
end

--- Drops the head of the queue and, when it belongs to a group, the rest of its group.
local function DropHead()
	local message = table.remove(queue, 1)
	stats.dropped = stats.dropped + 1
	if message and message.group then
		for index = #queue, 1, -1 do
			if queue[index].group == message.group then
				table.remove(queue, index)
				stats.dropped = stats.dropped + 1
			end
		end
		Events.Fire("QT_COMM_DROPPED", message.group)
	end
end

local function Locked()
	return C_ChatInfo.InChatMessagingLockdown and ns.Bool(C_ChatInfo.InChatMessagingLockdown()) == true
end

local StartPump

local function Resume()
	if not paused then
		return
	end
	if Locked() or GetTime() - pausedAt < pauseSeconds then
		return
	end
	paused = false
	resumedAt = GetTime()
	if resumeTicker then
		resumeTicker:Cancel()
		resumeTicker = nil
	end
	Events.Fire("QT_COMM_RESUMED")
end

--- Stops sending until the lockdown is over; what was queued is stale by then.
local function Pause()
	stats.lockdowns = stats.lockdowns + 1
	wipe(queue)
	StopPump()
	local now = GetTime()
	-- Locked again right after resuming: whatever restricts messages isn't over.
	if now - resumedAt < MAX_PAUSE_SECONDS then
		pauseSeconds = math.min(pauseSeconds * 2, MAX_PAUSE_SECONDS)
	else
		pauseSeconds = RESUME_CHECK_SECONDS
	end
	paused, pausedAt = true, now
	if not resumeTicker then
		resumeTicker = C_Timer.NewTicker(RESUME_CHECK_SECONDS, Resume)
	end
end

local function Pump()
	local message = queue[1]
	if not message then
		StopPump()
		return
	end
	if not Roster.InGroup() then
		wipe(queue)
		StopPump()
		return
	end
	local now = GetTime()
	if message.notBefore and message.notBefore > now then
		return
	end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, Transport.PREFIX, message.text, CHANNEL)
	result = ok and result
	stats.lastResult = ok and result or "error"
	if ok and (result == nil or result == true or result == SUCCESS) then
		table.remove(queue, 1)
		stats.sent = stats.sent + 1
		stats.bytesOut = stats.bytesOut + #message.text
	elseif THROTTLED[result] then
		stats.throttled = stats.throttled + 1
		message.attempts = message.attempts + 1
		if message.attempts > MAX_ATTEMPTS then
			DropHead()
		else
			message.notBefore = now + 2 ^ (message.attempts - 1)
		end
	elseif result == LOCKDOWN then
		Pause()
	elseif result == NOT_IN_GROUP then
		stats.dropped = stats.dropped + #queue
		wipe(queue)
		StopPump()
	else
		DropHead()
	end
end

function StartPump()
	if paused or pump or not queue[1] then
		return
	end
	pump = C_Timer.NewTicker(SEND_INTERVAL, Pump)
	Pump()
end

--- Queues a message for the party. Returns false when it can't be sent now (not grouped,
--- not registered, or paused by a lockdown).
---@param text string
---@param group string? drop these messages together if one of them can't be sent
---@return boolean queued
function Transport.Send(text, group)
	if not registered or paused or not Roster.InGroup() then
		return false
	end
	if #queue >= MAX_QUEUE then
		stats.dropped = stats.dropped + 1
		return false
	end
	queue[#queue + 1] = { text = text, group = group, attempts = 0 }
	StartPump()
	return true
end

--- Removes queued messages of a group (a newer full state replaces an unsent one).
---@param group string
function Transport.Discard(group)
	for index = #queue, 1, -1 do
		if queue[index].group == group then
			table.remove(queue, index)
		end
	end
end

---@return boolean
function Transport.IsPaused()
	return paused
end

---@return integer
function Transport.QueueLength()
	return #queue
end

function Transport.Stats()
	return stats
end

local function OnAddonMessage(prefix, text, channel, sender)
	if ns.Str(prefix) ~= Transport.PREFIX then
		return
	end
	text, channel, sender = ns.Str(text), ns.Str(channel), ns.Str(sender)
	if not (text and sender) or (channel ~= "PARTY" and channel ~= "RAID") then
		return
	end
	-- Party messages come back to their sender too.
	if Names.IsPlayer(sender) then
		return
	end
	local member = Roster.FindBySender(sender)
	if not member then
		stats.unknownSender = stats.unknownSender + 1
		return
	end
	local message = Protocol.Parse(text)
	if not message then
		stats.malformed = stats.malformed + 1
		return
	end
	stats.received = stats.received + 1
	stats.bytesIn = stats.bytesIn + #text
	Events.Fire("QT_COMM_MESSAGE", member, message)
end

--- Registers the message prefix. Called at PLAYER_LOGIN.
function Transport.Init()
	local ok = pcall(C_ChatInfo.RegisterAddonMessagePrefix, Transport.PREFIX)
	registered = ok
	Events.On("CHAT_MSG_ADDON", OnAddonMessage)
	Events.On("ADDON_RESTRICTION_STATE_CHANGED", Resume)
end
