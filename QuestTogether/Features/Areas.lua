local _, ns = ...

--- Decides which quests the panel shows.
---
---   areas  quests whose area (the shape the map draws) the player is standing in. The game
---          reports entering and leaving areas; a slow poll backs that up. A quest stays
---          for a few seconds after the player leaves its area, and a quest finished in its
---          area stays until everyone with known progress has finished it, the player
---          changes zone, or ten minutes pass (its area disappears from the map once done).
---   zone   quests the map shows in the current zone (also used when the client can't
---          tell areas).
---   all    every quest someone in the party has too.
---
--- Fires QT_AREAS_CHANGED when the set of quests the player is in changes.
---@class QTAreas
local Areas = ns.Areas
local Scanner = ns.Scanner
local Roster = ns.Roster
local PartyState = ns.PartyState
local Database = ns.Database
local Events = ns.Events

local POLL_SECONDS = 2
local LEAVE_GRACE = 5
local STICKY_SECONDS = 600

local inside = {} ---@type table<integer, boolean>
local lastInsideAt = {} ---@type table<integer, number>
local sticky = {} ---@type table<integer, number> quest ID -> when it was finished in its area
local poller
local stats = { polls = 0, events = 0, changes = 0 }

---@return boolean
function Areas.HasApi()
	return C_Minimap ~= nil and C_Minimap.IsInsideQuestBlob ~= nil
end

local function Changed()
	stats.changes = stats.changes + 1
	Events.Fire("QT_AREAS_CHANGED")
end

---@return boolean changed
local function Set(questID, isInside)
	if isInside then
		lastInsideAt[questID] = GetTime()
	end
	if (inside[questID] == true) == isInside then
		return false
	end
	inside[questID] = isInside or nil
	return true
end

--- Asks the game, for every unfinished quest, whether the player is in its area.
local function Poll()
	if not Areas.HasApi() then
		return
	end
	stats.polls = stats.polls + 1
	local changed = false
	for _, questID in ipairs(Scanner.Quests()) do
		local quest = Scanner.Get(questID)
		if quest and not quest.complete then
			local ok, isInside = pcall(C_Minimap.IsInsideQuestBlob, questID)
			isInside = ok and ns.Bool(isInside)
			if isInside ~= nil and Set(questID, isInside) then
				changed = true
			end
		end
	end
	if changed then
		Changed()
	end
end

local function Needed()
	return Database.Get("panelEnabled") and Database.Get("panelMode") == "areas" and Roster.InGroup()
end

--- Starts or stops the poll to match the settings and the group.
function Areas.Update()
	if Needed() and Areas.HasApi() then
		if not poller then
			poller = C_Timer.NewTicker(POLL_SECONDS, Poll)
			Poll()
		end
	elseif poller then
		poller:Cancel()
		poller = nil
	end
end

---@param questID integer
---@return boolean
function Areas.IsInside(questID)
	return inside[questID] == true
end

--- Everyone with known progress has finished the quest.
local function EveryoneDone(questID, quest)
	for _, member in ipairs(Roster.Members()) do
		local status, progress = PartyState.Status(member, questID, #quest.objectives)
		if status == "progress" and progress.state ~= "c" then
			return false
		end
	end
	return true
end

local function ShownForArea(questID, quest, now)
	if inside[questID] then
		return true
	end
	if sticky[questID] then
		if now - sticky[questID] < STICKY_SECONDS and not EveryoneDone(questID, quest) then
			return true
		end
		sticky[questID] = nil
	end
	local last = lastInsideAt[questID]
	return not quest.complete and last ~= nil and now - last < LEAVE_GRACE
end

local function SharedWithParty(questID, quest)
	for _, member in ipairs(Roster.Members()) do
		if PartyState.Shares(member, questID, #quest.objectives) then
			return true
		end
	end
	return false
end

---@return "areas"|"zone"|"all"
function Areas.Mode()
	local mode = Database.Get("panelMode")
	if mode == "areas" and not Areas.HasApi() then
		return "zone"
	end
	return mode
end

--- The quests the panel shows, in quest log order with the areas the player is in first.
---@param into integer[] receives the quest IDs (wiped first)
---@return integer[] into
function Areas.Visible(into)
	wipe(into)
	local mode = Areas.Mode()
	local now = GetTime()
	local insideCount = 0
	for _, questID in ipairs(Scanner.Quests()) do
		local quest = Scanner.Get(questID)
		if quest and quest.visible > 0 then
			local shown
			if mode == "areas" then
				shown = ShownForArea(questID, quest, now)
			elseif mode == "zone" then
				shown = quest.isOnMap
			else
				shown = SharedWithParty(questID, quest)
			end
			if shown then
				if mode == "areas" and inside[questID] then
					insideCount = insideCount + 1
					table.insert(into, insideCount, questID)
				else
					into[#into + 1] = questID
				end
			end
		end
	end
	return into
end

--- Seconds until a quest that was just left (or finished) drops off, for scheduling a refresh.
---@return number?
function Areas.NextExpiry()
	local now, soonest = GetTime(), nil
	for questID, at in pairs(lastInsideAt) do
		local left = at + LEAVE_GRACE - now
		if not inside[questID] and left > 0 and (not soonest or left < soonest) then
			soonest = left
		end
	end
	return soonest
end

--- What the game said about each quest, for /qt debug areas.
---@return table<integer, {now: boolean?, inside: boolean, sticky: boolean}>
function Areas.Probe()
	local result = {}
	for _, questID in ipairs(Scanner.Quests()) do
		local value
		if Areas.HasApi() then
			local ok, isInside = pcall(C_Minimap.IsInsideQuestBlob, questID)
			value = ok and ns.Bool(isInside) or nil
		end
		result[questID] = { now = value, inside = inside[questID] == true, sticky = sticky[questID] ~= nil }
	end
	return result, stats
end

Events.On("PLAYER_INSIDE_QUEST_BLOB_STATE_CHANGED", function(questID, isInside)
	questID, isInside = ns.Num(questID), ns.Bool(isInside)
	local quest = questID and Scanner.Get(questID)
	-- A finished quest's area is gone from the map; the poll skips finished quests too.
	if isInside and quest and quest.complete then
		return
	end
	if questID and isInside ~= nil then
		stats.events = stats.events + 1
		if Set(questID, isInside) then
			Changed()
		end
	end
end)

-- A quest finished in (or just after leaving) its area stays on the panel.
Events.On("QT_QUEST_DONE", function(questID)
	local last = lastInsideAt[questID]
	if inside[questID] or (last and GetTime() - last < LEAVE_GRACE) then
		sticky[questID] = GetTime()
	end
	if inside[questID] then
		inside[questID] = nil
	end
	Changed()
end)

Events.On("QT_QUEST_REMOVED", function(questID)
	inside[questID], lastInsideAt[questID], sticky[questID] = nil, nil, nil
	Changed()
end)

Events.On("ZONE_CHANGED_NEW_AREA", function()
	if next(sticky) then
		wipe(sticky)
		Changed()
	end
	if poller then
		Poll()
	end
end)

local function Recheck()
	if poller then
		Events.Debounce("areasRecheck", 0.2, Poll)
	end
end
Events.On("ZONE_CHANGED", Recheck)
Events.On("ZONE_CHANGED_INDOORS", Recheck)
Events.On("QUEST_POI_UPDATE", Recheck)
Events.On("QT_SCAN_DONE", Recheck)

Events.On("QT_ROSTER_CHANGED", Areas.Update)
Events.On("QT_SETTINGS_CHANGED", function(key)
	if key == "panelEnabled" or key == "panelMode" then
		Areas.Update()
	end
end)
