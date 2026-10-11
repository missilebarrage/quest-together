local _, ns = ...

--- Party members' progress as the game itself reports it (the party lines Blizzard shows in
--- quest tooltips, via C_TooltipInfo.GetQuestPartyProgress). Used for members who don't
--- run the addon. The data is text, so it's read conservatively: a member's lines count
--- only when every objective line carries a "n/m" count or is marked complete, and when
--- they have as many objectives as the player's copy of the quest.
---@class QTGameProgress
local GameProgress = ns.GameProgress
local Roster = ns.Roster
local Events = ns.Events

local CACHE_SECONDS = 2
-- After a party member's log changes, answers this old are asked again.
local MIN_AGE = 1
local QUEST_PLAYER = 18
local QUEST_OBJECTIVE = 8

local cache = {} ---@type table<integer, {at: number, byGUID: table<string, QTPeerQuest>}>
local invalidatedAt = -math.huge
local stats = { queries = 0, members = 0, rejected = 0 }

local function LineTypes()
	local types = Enum and Enum.TooltipDataLineType
	return types and types.QuestPlayer or QUEST_PLAYER, types and types.QuestObjective or QUEST_OBJECTIVE
end

local function Plain(text)
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Finish(entry, byGUID)
	if entry and entry.valid and #entry.record.counts > 0 then
		byGUID[entry.guid] = entry.record
	elseif entry then
		stats.rejected = stats.rejected + 1
	end
end

--- Reads the tooltip data for one quest into { [guid] = record }.
local function Read(questID)
	local byGUID = {}
	if not (C_TooltipInfo and C_TooltipInfo.GetQuestPartyProgress) then
		return byGUID
	end
	stats.queries = stats.queries + 1
	local ok, data = pcall(C_TooltipInfo.GetQuestPartyProgress, questID, true, true)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then
		return byGUID
	end
	local playerType, objectiveType = LineTypes()
	local entry
	for _, line in ipairs(data.lines) do
		local lineType = ns.Num(line.type)
		local text = ns.Str(line.leftText)
		if lineType == playerType then
			Finish(entry, byGUID)
			entry = nil
			local member = text and Roster.FindByName(Plain(text))
			if member then
				entry = { guid = member.guid, valid = true, record = { questID = questID, state = "-", counts = {} } }
			end
		elseif lineType == objectiveType and entry then
			local completed = ns.Bool(line.completed) == true
			local fulfilled, required = (text and Plain(text) or ""):match("(%d+)%s*/%s*(%d+)")
			fulfilled, required = tonumber(fulfilled), tonumber(required)
			local counts = entry.record.counts
			if fulfilled and required and required > 0 then
				-- Same rule as the player's own objectives: unfinished never shows a full count.
				fulfilled = completed and required or math.min(fulfilled, required - 1)
			elseif completed then
				fulfilled, required = 1, 1
			else
				entry.valid = false
			end
			counts[#counts + 1] = fulfilled or 0
			counts[#counts + 1] = required or 1
		end
	end
	Finish(entry, byGUID)
	for _, record in pairs(byGUID) do
		local allDone = true
		for index = 1, #record.counts, 2 do
			allDone = allDone and record.counts[index] >= record.counts[index + 1]
		end
		record.state = allDone and "c" or "-"
	end
	return byGUID
end

--- A member's progress on a quest according to the game, or nil when it has none to give
--- (or it doesn't match the player's copy of the quest).
---@param member QTMember
---@param questID integer
---@param numObjectives integer
---@return QTPeerQuest?
function GameProgress.Get(member, questID, numObjectives)
	local entry = cache[questID]
	local now = GetTime()
	local age = entry and now - entry.at
	if not entry or age > CACHE_SECONDS or (entry.at <= invalidatedAt and age >= MIN_AGE) then
		entry = { at = now, byGUID = Read(questID) }
		cache[questID] = entry
	end
	local record = entry.byGUID[member.guid]
	if record and #record.counts == numObjectives * 2 then
		stats.members = stats.members + 1
		return record
	end
	return nil
end

--- The raw lines for one quest, for /qt debug tooltip: line types and how many members
--- and objectives were understood. Never returns names or text.
---@param questID integer
---@return table summary
function GameProgress.Probe(questID)
	local summary = { available = C_TooltipInfo ~= nil and C_TooltipInfo.GetQuestPartyProgress ~= nil, types = {} }
	if not summary.available then
		return summary
	end
	local ok, data = pcall(C_TooltipInfo.GetQuestPartyProgress, questID, true, true)
	summary.ok = ok
	summary.lines = ok and type(data) == "table" and type(data.lines) == "table" and #data.lines or 0
	if summary.lines > 0 then
		for _, line in ipairs(data.lines) do
			local lineType = ns.Num(line.type) or -1
			summary.types[lineType] = (summary.types[lineType] or 0) + 1
		end
	end
	summary.members = {}
	for guid, record in pairs(Read(questID)) do
		local member = Roster.FindByGUID(guid)
		summary.members[#summary.members + 1] = (member and member.unit or "?") .. "=" .. (#record.counts / 2)
	end
	table.sort(summary.members)
	return summary
end

function GameProgress.Stats()
	return stats
end

local function Changed()
	Events.Fire("QT_PARTY_CHANGED")
end

-- A party member's quest log changed: what the game reported may be out of date. (In a raid
-- this fires for everyone; only the player's party matters.)
Events.On("UNIT_QUEST_LOG_CHANGED", function(unit)
	unit = ns.Str(unit)
	if unit and unit:find("^party%d$") then
		invalidatedAt = GetTime()
		Events.Debounce("gameProgressChanged", MIN_AGE, Changed)
	end
end)
Events.On("QT_ROSTER_CHANGED", function()
	wipe(cache)
end)
