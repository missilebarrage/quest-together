local _, ns = ...

--- Recognizes the game's answers to sharing a quest ("Sharing quest with X...", "X has
--- accepted your quest", "X is busy", ...) and fires QT_PUSH_RESULT(kind, member). They
--- arrive as UI info messages or system chat messages; both are understood, and the same
--- answer arriving both ways counts once. The answers don't say which quest they're about.
---@class QTPushResults
local PushResults = ns.PushResults
local Roster = ns.Roster
local Events = ns.Events

local DUPLICATE_SECONDS = 0.5

--- Result global strings and what they mean. Unlisted ERR_QUEST_PUSH_* messages (level,
--- class, race requirements...) count as "ineligible".
PushResults.KINDS = {
	ERR_QUEST_PUSH_SUCCESS_S = "sending",
	ERR_QUEST_PUSH_ACCEPTED_S = "accepted",
	ERR_QUEST_PUSH_DECLINED_S = "declined",
	ERR_QUEST_PUSH_BUSY_S = "busy",
	ERR_QUEST_PUSH_ONQUEST_S = "onQuest",
	ERR_QUEST_PUSH_ALREADY_DONE_S = "completed",
	ERR_QUEST_PUSH_ALREADY_DONE_TO_RECIPIENT_S = "completed",
	ERR_QUEST_PUSH_INVALID_S = "ineligible",
	ERR_QUEST_PUSH_INVALID_TO_RECIPIENT_S = "ineligible",
	ERR_QUEST_PUSH_NOT_ALLOWED_S = "ineligible",
	ERR_QUEST_PUSH_DIFFERENT_SERVER_DAILY_S = "ineligible",
	ERR_QUEST_PUSH_LOG_FULL_S = "logFull",
	ERR_QUEST_PUSH_TOO_FAR_S = "tooFar",
	ERR_QUEST_PUSH_TIMER_EXPIRED_S = "expired",
	ERR_QUEST_PUSH_NOT_IN_PARTY_S = "notInParty",
}

local DEFAULT_KIND = "ineligible"
local NAME_PREFIX = "ERR_QUEST_PUSH_"

local patterns = {} ---@type {name: string, kind: string, pattern: string, order: integer[]}[]
local patternsByName = {} ---@type table<string, table>
local lastKind, lastName, lastAt
local recent = {} ---@type {at: number, kind: string, unit: string?}[] for /qt debug share

local function Compile(name, kind)
	local format = ns.Str(_G[name])
	if not format or format == "" then
		return nil
	end
	local pattern, order = ns.FormatPattern(format)
	local entry = { name = name, kind = kind, pattern = pattern, order = order }
	patternsByName[name] = entry
	return entry
end

local function Build()
	wipe(patterns)
	wipe(patternsByName)
	local names = {}
	for name in pairs(PushResults.KINDS) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local entry = Compile(name, PushResults.KINDS[name])
		if entry then
			patterns[#patterns + 1] = entry
		end
	end
end

local function Report(kind, name)
	local now = GetTime()
	if kind == lastKind and name == lastName and lastAt and now - lastAt < DUPLICATE_SECONDS then
		return
	end
	lastKind, lastName, lastAt = kind, name, now
	local member = name and Roster.FindByName(name)
	table.insert(recent, 1, { at = now, kind = kind, unit = member and member.unit })
	recent[11] = nil
	Events.Fire("QT_PUSH_RESULT", kind, member)
end

---@param message string
---@param entry table
local function Try(message, entry)
	local name = ns.MatchFormat(message, entry.pattern, entry.order)
	if name ~= nil or message:match(entry.pattern) then
		Report(entry.kind, name)
		return true
	end
	return false
end

--- Recognizes a result message; returns whether it was one.
---@param message string
---@param errorName string? the message's GetGameMessageInfo name, when known
---@return boolean
function PushResults.Handle(message, errorName)
	if errorName then
		if errorName:sub(1, #NAME_PREFIX) ~= NAME_PREFIX then
			return false
		end
		local entry = patternsByName[errorName] or Compile(errorName, PushResults.KINDS[errorName] or DEFAULT_KIND)
		if entry and Try(message, entry) then
			return true
		end
		Report(PushResults.KINDS[errorName] or DEFAULT_KIND, nil)
		return true
	end
	for _, entry in ipairs(patterns) do
		if Try(message, entry) then
			return true
		end
	end
	return false
end

function PushResults.Recent()
	return recent
end

local function OnInfoMessage(errorType, message)
	message = ns.Str(message)
	if not message then
		return
	end
	local errorName
	if GetGameMessageInfo and ns.Num(errorType) then
		local ok, name = pcall(GetGameMessageInfo, errorType)
		errorName = ok and ns.Str(name) or nil
	end
	PushResults.Handle(message, errorName)
end

--- Compiles the result patterns from the client's strings. Called at PLAYER_LOGIN.
function PushResults.Init()
	Build()
	Events.On("UI_INFO_MESSAGE", OnInfoMessage)
	Events.On("UI_ERROR_MESSAGE", OnInfoMessage)
	Events.On("CHAT_MSG_SYSTEM", function(message)
		-- Unreadable (secret) while chat is locked down.
		message = ns.Str(message)
		if message then
			PushResults.Handle(message)
		end
	end)
end
