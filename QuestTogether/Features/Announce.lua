local _, ns = ...

--- Posts finished objectives and completed quests in party chat, worded like Questie:
---   {rt1} 6/6 Boar slain for [The Boar Hunt]!
---   {rt1} Quest Completed: [The Boar Hunt]
--- Only what the player is seen to finish is posted, each objective once: logging in with
--- finished objectives, or dropping below a count and getting back to it, posts nothing.
--- A quest that is turned in or abandoned can post again when it's picked up next time.
--- Lines wait while chat is locked down and are dropped when they've become stale.
---@class QTAnnounce
local Announce = ns.Announce
local Scanner = ns.Scanner
local QuestLog = ns.QuestLog
local Roster = ns.Roster
local Database = ns.Database
local Format = ns.Format
local Events = ns.Events
local L = ns.L

local CHANNEL = "PARTY"
local MAX_BYTES = 255
local MAX_QUEUE = 10
local SEND_INTERVAL = 0.3
local MAX_AGE = 120
local LOCKDOWN_CHECK_SECONDS = 5
local QUEST_KEY = "Q"

-- announced[questID][objectiveIndex or "Q"] = true
local announced = {} ---@type table<integer, table>
local queue = {} ---@type {text: string, at: number}[]
local pump
local blocked = false
local stats = { sent = 0, stale = 0, overflow = 0, lockdownWaits = 0, failed = 0 }

local function Mark(questID, key)
	local keys = announced[questID]
	if not keys then
		keys = {}
		announced[questID] = keys
	end
	if keys[key] then
		return false
	end
	keys[key] = true
	return true
end

local function Locked()
	return C_ChatInfo.InChatMessagingLockdown and ns.Bool(C_ChatInfo.InChatMessagingLockdown()) == true
end

local function StopPump()
	if pump then
		pump:Cancel()
		pump = nil
	end
end

local StartPump

local function Pump()
	local entry = queue[1]
	if not entry or blocked or not Roster.InParty() then
		wipe(queue)
		StopPump()
		return
	end
	if GetTime() - entry.at > MAX_AGE then
		table.remove(queue, 1)
		stats.stale = stats.stale + 1
		return
	end
	if Locked() then
		-- Check again now and then; ADDON_RESTRICTION_STATE_CHANGED usually comes first.
		stats.lockdownWaits = stats.lockdownWaits + 1
		StopPump()
		pump = C_Timer.NewTimer(LOCKDOWN_CHECK_SECONDS, function()
			pump = nil
			StartPump()
		end)
		return
	end
	table.remove(queue, 1)
	local ok = pcall(C_ChatInfo.SendChatMessage, entry.text, CHANNEL)
	if ok then
		stats.sent = stats.sent + 1
	else
		stats.failed = stats.failed + 1
	end
end

function StartPump()
	if pump or not queue[1] then
		return
	end
	pump = C_Timer.NewTicker(SEND_INTERVAL, Pump)
	Pump()
end

---@param text string
local function Queue(text)
	if blocked or not Roster.InParty() then
		return
	end
	if #queue >= MAX_QUEUE then
		table.remove(queue, 1)
		stats.overflow = stats.overflow + 1
	end
	queue[#queue + 1] = { text = text, at = GetTime() }
	StartPump()
end

--- Fits "format(text, link)" into one chat message by shortening the text, never the link.
local function Compose(format, text, link)
	local message = format:format(text, link)
	if #message > MAX_BYTES then
		local room = MAX_BYTES - (#message - #text)
		message = format:format(Format.TruncateBytes(text, math.max(0, room)), link)
	end
	return message
end

--- The line posted for a finished objective.
---@param quest QTQuest
---@param index integer
---@return string
function Announce.ObjectiveLine(quest, index)
	local text = QuestLog.ObjectiveText(quest.objectives[index])
	return Compose(L.ANNOUNCE_OBJECTIVE, text, QuestLog.Link(quest.questID, quest.title))
end

--- The line posted for a completed quest.
---@param quest QTQuest
---@return string
function Announce.QuestLine(quest)
	return L.ANNOUNCE_QUEST:format(QuestLog.Link(quest.questID, quest.title))
end

function Announce.Stats()
	return stats, #queue, blocked
end

-- What a quest already has when it's first seen is never announced.
Events.On("QT_QUEST_ADDED", function(questID)
	local quest = Scanner.Get(questID)
	if not quest then
		return
	end
	for index, objective in ipairs(quest.objectives) do
		if objective.done then
			Mark(questID, index)
		end
	end
	if quest.complete then
		Mark(questID, QUEST_KEY)
	end
end)

Events.On("QT_OBJECTIVE_DONE", function(questID, index, silent)
	local quest = Scanner.Get(questID)
	if not quest or not Mark(questID, index) or silent then
		return
	end
	-- An objective without text can't be put into words.
	if Database.Get("announceObjectives") and not quest.objectives[index].hidden then
		Queue(Announce.ObjectiveLine(quest, index))
	end
end)

Events.On("QT_QUEST_DONE", function(questID, _, silent)
	local quest = Scanner.Get(questID)
	if not quest or quest.failed or not Mark(questID, QUEST_KEY) or silent then
		return
	end
	if Database.Get("announceQuests") then
		Queue(Announce.QuestLine(quest))
	end
end)

Events.On("QT_QUEST_REMOVED", function(questID)
	announced[questID] = nil
end)

Events.On("ADDON_RESTRICTION_STATE_CHANGED", function()
	if queue[1] and not Locked() then
		if pump then
			pump:Cancel()
			pump = nil
		end
		StartPump()
	end
end)

local function OnBlocked(addonName, func)
	if ns.Str(addonName) ~= ns.NAME or blocked then
		return
	end
	func = ns.Str(func) or ""
	if func:find("SendChatMessage", 1, true) then
		blocked = true
		wipe(queue)
		StopPump()
		ns.Print(L.ANNOUNCE_BLOCKED)
	end
end
Events.On("ADDON_ACTION_BLOCKED", OnBlocked)
Events.On("ADDON_ACTION_FORBIDDEN", OnBlocked)

--- Mentions once that Questie posts objectives too. Called at PLAYER_LOGIN.
function Announce.Init()
	local questie = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Questie")
	if questie and Database.Get("announceObjectives") and Database.FirstTime("questieNotice") then
		ns.Print(L.QUESTIE_NOTICE)
	end
end
