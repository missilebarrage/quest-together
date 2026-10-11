local _, ns = ...

--- Notices quests a party member shares with the player (the quest dialog opens with a
--- player, not an NPC, as the giver) and, when the option is on, accepts them. Sharing
--- uses this to avoid sharing such a quest straight back.
---@class QTAutoAccept
local AutoAccept = ns.AutoAccept
local Roster = ns.Roster
local QuestLog = ns.QuestLog
local Database = ns.Database
local Events = ns.Events
local L = ns.L

local REMEMBER_SECONDS = 600

local received = {} ---@type table<integer, number> quest ID -> when a party member shared it
local disabled = false
local stats = { shares = 0, accepted = 0 }

--- Whether a party member shared this quest with the player recently.
---@param questID integer
---@return boolean
function AutoAccept.WasShared(questID)
	local at = received[questID]
	return at ~= nil and GetTime() - at < REMEMBER_SECONDS
end

function AutoAccept.Stats()
	return stats, disabled
end

--- The party member offering the quest in the open quest dialog, if it's one.
---@return QTMember?
local function Giver()
	local guid = ns.Str(UnitGUID("questnpc"))
	if not guid or not guid:find("^Player%-") or guid == ns.Str(UnitGUID("player")) then
		return nil
	end
	return Roster.FindByGUID(guid)
end

Events.On("QUEST_DETAIL", function()
	local questID = ns.Num(GetQuestID())
	if not questID or questID <= 0 then
		return
	end
	local giver = Giver()
	if not giver then
		return
	end
	stats.shares = stats.shares + 1
	received[questID] = GetTime()
	if Database.Get("autoAccept") and not disabled and not QuestLog.IsOnQuest(questID) then
		stats.accepted = stats.accepted + 1
		AcceptQuest()
	end
end)

Events.On("QUEST_TURNED_IN", function(questID)
	questID = ns.Num(questID)
	if questID then
		received[questID] = nil
	end
end)

local function OnBlocked(addonName, func)
	if ns.Str(addonName) ~= ns.NAME or disabled then
		return
	end
	func = ns.Str(func) or ""
	if func:find("AcceptQuest", 1, true) then
		disabled = true
		ns.Print(L.AUTO_ACCEPT_BLOCKED)
	end
end
Events.On("ADDON_ACTION_BLOCKED", OnBlocked)
Events.On("ADDON_ACTION_FORBIDDEN", OnBlocked)
