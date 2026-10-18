local _, ns = ...

--- At every level-up, posts in party chat how many quests the player turned in at the level
--- they just finished: "[Quest Together]: 7 quests completed at Level 12!"
---
--- A quest counts toward the level the player had when its reward window opened, so the
--- turn-in that levels the player up counts toward the old level even though the game
--- reports the level-up first. The count is kept per character across sessions. A level the
--- addon only saw part of (it was installed partway through, say) isn't posted: the player
--- is told why instead.
---@class QTLevels
local Levels = ns.Levels
local Database = ns.Database
local Roster = ns.Roster
local Events = ns.Events
local L = ns.L

-- The turn-in that caused a level-up arrives just after it.
local WAIT_SECONDS = 3

local completedAt = {} ---@type table<integer, integer> quest ID -> level when its reward window opened
local pending ---@type {level: integer, quests: integer, partial: boolean}?
local levelUpAt, levelUpFrom
local timer

local function Level()
	return ns.Num(UnitLevel("player"))
end

--- "1 quest completed at Level 4" / "7 quests ..." as posted.
---@param quests integer
---@param level integer
---@return string
function Levels.Line(quests, level)
	local count = (quests == 1 and L.QUESTS_ONE or L.QUESTS_MANY):format(quests)
	return L.ANNOUNCE_LEVEL:format(count, level)
end

local function Post()
	timer = nil
	local finished = pending
	pending = nil
	if not finished or not Database.Get("announceLevels") or not Roster.InParty() then
		return
	end
	if finished.partial then
		ns.Print(L.LEVEL_PARTLY_TRACKED:format(finished.level))
		return
	end
	ns.Announce.Post(Levels.Line(finished.quests, finished.level))
end

--- Starts counting for the character's current level. Called at PLAYER_LOGIN, after the
--- character data has been claimed.
function Levels.Init()
	local char, level = Database.Char(), Level()
	if not (char and level) then
		return
	end
	if char.level ~= level or type(char.quests) ~= "number" then
		-- First time at this level, as far as the addon knows: unless the level has only just
		-- begun, some of it happened without the addon.
		char.level, char.quests = level, 0
		char.partial = (ns.Num(UnitXP("player")) or 0) > 0
	end
end

--- The level and count being kept, for /qt debug.
---@return integer? level
---@return integer? quests
---@return boolean? partial
function Levels.State()
	local char = Database.Char()
	if char then
		return char.level, char.quests, char.partial
	end
end

Events.On("QUEST_COMPLETE", function()
	local questID, level = ns.Num(GetQuestID()), Level()
	if questID and questID > 0 and level then
		completedAt[questID] = level
	end
end)

Events.On("QUEST_TURNED_IN", function(questID)
	questID = ns.Num(questID)
	local char = Database.Char()
	if not (questID and char and char.level) then
		return
	end
	local level = completedAt[questID]
	completedAt[questID] = nil
	if not level then
		-- Turned in without a reward window: right after a level-up, it's what caused it.
		local recent = levelUpAt and GetTime() - levelUpAt < WAIT_SECONDS
		level = recent and levelUpFrom or char.level
	end
	if pending and level == pending.level then
		pending.quests = pending.quests + 1
	elseif level == char.level then
		char.quests = char.quests + 1
	end
end)

Events.On("PLAYER_LEVEL_UP", function(newLevel)
	newLevel = ns.Num(newLevel)
	local char = Database.Char()
	if not (newLevel and char and char.level) or newLevel <= char.level then
		return
	end
	if pending then
		-- Two level-ups in a row: post the first one now.
		if timer then
			timer:Cancel()
		end
		Post()
	end
	pending = { level = char.level, quests = char.quests or 0, partial = char.partial == true }
	levelUpAt, levelUpFrom = GetTime(), char.level
	char.level, char.quests, char.partial = newLevel, 0, false
	timer = C_Timer.NewTimer(WAIT_SECONDS, Post)
end)
